# frozen_string_literal: true

require "sidekiq"
require "patient_http"

module PatientHttp
  # Runs HTTP requests from Sidekiq on an async I/O processor in the same
  # process. Worker threads are free to run other jobs while requests are in
  # flight.
  #
  # == Usage
  #
  # Make requests with the +PatientHttp+ module methods:
  #
  #   PatientHttp.get(
  #     "https://api.example.com/users/123",
  #     callback: MyCallback,
  #     callback_args: {user_id: 123}
  #   )
  #
  # Define a callback service class with +on_complete+ and +on_error+ methods:
  #
  #   class MyCallback
  #     def on_complete(response)
  #       user_id = response.callback_args[:user_id]
  #       User.find(user_id).update!(data: response.json)
  #     end
  #
  #     def on_error(error)
  #       Rails.logger.error("Request failed: #{error.message}")
  #     end
  #   end
  #
  # Set Sidekiq job options for the requests made in a block:
  #
  #   PatientHttp::Sidekiq.with_sidekiq_options(queue: "high_priority") do
  #     PatientHttp.get("https://api.example.com/users/123", callback: MyCallback)
  #   end
  #
  # == Processors
  #
  # This module manages the processors for the current process. It starts one
  # processor for each configured processor profile when the Sidekiq server
  # starts, and stops them when the server shuts down. All processors in a
  # process share one crash-recovery monitor, one stats aggregator, and one
  # Redis pool.
  module Sidekiq
    # The gem version.
    VERSION = File.read(File.expand_path("../../../VERSION", __FILE__)).strip

    # Sidekiq-specific autoloads
    autoload :CallbackWorker, File.join(__dir__, "sidekiq/callback_worker")
    autoload :Configuration, File.join(__dir__, "sidekiq/configuration")
    autoload :Context, File.join(__dir__, "sidekiq/context")
    autoload :DirectTaskHandler, File.join(__dir__, "sidekiq/direct_task_handler")
    autoload :ProcessorObserver, File.join(__dir__, "sidekiq/processor_observer")
    autoload :RedisPool, File.join(__dir__, "sidekiq/redis_pool")
    autoload :RequestExecutor, File.join(__dir__, "sidekiq/request_executor")
    autoload :RequestWorker, File.join(__dir__, "sidekiq/request_worker")
    autoload :LifecycleHooks, File.join(__dir__, "sidekiq/lifecycle_hooks")
    autoload :TaskHandler, File.join(__dir__, "sidekiq/task_handler")
    autoload :Stats, File.join(__dir__, "sidekiq/stats")
    autoload :TaskMonitor, File.join(__dir__, "sidekiq/task_monitor")
    autoload :TaskMonitorThread, File.join(__dir__, "sidekiq/task_monitor_thread")
    autoload :WebUI, File.join(__dir__, "sidekiq/web_ui")

    @processors = {}
    @after_completion_callbacks = []
    @after_error_callbacks = []
    @external_storage = nil
    @request_handler = nil
    @lifecycle_mutex = Mutex.new
    @redis_pool = nil
    @stats = nil
    @task_monitor = nil
    @monitor_thread = nil

    class << self
      # Sets the configuration. Intended for tests.
      #
      # +PatientHttp+ stores the configuration, so this method assigns it there.
      #
      # @param config [Configuration, nil] The configuration, or +nil+ to build a
      #   new one on next use.
      # @return [void]
      def configuration=(config)
        PatientHttp.default_configuration = config
      end

      # Yields the configuration to a block.
      #
      # Every call yields the same configuration object, so options accumulate.
      # Several initializers can each set options without overwriting one
      # another. +PatientHttp.configure+ calls this method, so application code
      # can use either one.
      #
      # @example
      #   PatientHttp.configure do |config|
      #     config.max_connections = 512
      #   end
      #
      # @yield [config] The block that sets configuration options.
      # @yieldparam config [Configuration] The configuration.
      # @return [Configuration] The configuration.
      def configure
        config = configuration
        yield(config) if block_given?
        @external_storage = nil
        # Rebuild the stats aggregator from the new configuration unless a
        # running processor already owns it.
        @stats = nil unless running?
        config
      end

      # Returns the configuration for this process, and creates it on first use.
      #
      # +PatientHttp+ stores the configuration, so this method and
      # +PatientHttp.configuration+ return the same object. As a result, secrets
      # registered with +PatientHttp.register_secret+ reach the configuration
      # that the processors use, regardless of load order.
      #
      # @return [Configuration] The configuration.
      def configuration
        PatientHttp.configuration
      end

      # Builds a new configuration. +PatientHttp+ calls this method when it
      # creates the configuration for this process.
      #
      # @return [Configuration] The new configuration.
      # @api private
      def new_configuration
        Configuration.new
      end

      # Resets the configuration to the defaults. Intended for tests.
      #
      # @return [Configuration] The new configuration.
      def reset_configuration!
        @external_storage = nil
        PatientHttp.default_configuration = nil
        configuration
      end

      # Registers a block to run after each request completes. Use it for
      # monitoring. Blocks run in the order they're registered.
      #
      # @example
      #   PatientHttp::Sidekiq.after_completion do |response|
      #     StatsD.timing("patient_http.duration", response.duration * 1000)
      #   end
      #
      # @yield [response] The block to run.
      # @yieldparam response [PatientHttp::Response] The HTTP response.
      # @return [void]
      def after_completion(&block)
        @after_completion_callbacks << block
      end

      # Registers a block to run after each request error. Use it for
      # monitoring. Blocks run in the order they're registered.
      #
      # @example
      #   PatientHttp::Sidekiq.after_error do |error|
      #     StatsD.increment("patient_http.error.#{error.error_type}")
      #   end
      #
      # @yield [error] The block to run.
      # @yieldparam error [PatientHttp::Error] The error.
      # @return [void]
      def after_error(&block)
        @after_error_callbacks << block
      end

      # Adds the context middleware to the Sidekiq server middleware chain.
      #
      # The gem adds the middleware when it loads. Call this method again to
      # move the middleware to the end of the chain, after middleware that was
      # added later. For more control, add
      # PatientHttp::Sidekiq::Context::Middleware to the chain yourself.
      #
      # @return [void]
      def append_middleware
        ::Sidekiq.configure_server do |config|
          config.server_middleware do |chain|
            chain.add PatientHttp::Sidekiq::Context::Middleware
          end
        end
      end

      # Returns whether any processor is running.
      #
      # @return [Boolean] +true+ if any processor is running.
      def running?
        @processors.values.any?(&:running?)
      end

      # Returns whether any processor is draining. A draining processor doesn't
      # accept new requests but continues to run in-flight requests.
      #
      # @return [Boolean] +true+ if any processor is draining.
      def draining?
        @processors.values.any?(&:draining?)
      end

      # Returns whether any processor is stopping.
      #
      # @return [Boolean] +true+ if any processor is stopping.
      def stopping?
        @processors.values.any?(&:stopping?)
      end

      # Returns whether all processors are stopped.
      #
      # @return [Boolean] +true+ if all processors are stopped or none has
      #   started.
      def stopped?
        @processors.values.all?(&:stopped?)
      end

      # Returns the external storage for request and result payloads.
      #
      # @return [PatientHttp::ExternalStorage] The external storage.
      # @api private
      def external_storage
        @external_storage ||= PatientHttp::ExternalStorage.new(configuration)
      end

      # Encrypts data with the configured encryptor.
      #
      # @param data [Hash] The data to encrypt.
      # @return [Hash] The encrypted data, or the original data if encryption
      #   isn't configured.
      # @api private
      def encrypt(data)
        configuration.encryptor.encrypt(data)
      end

      # Decrypts data with the configured encryptor.
      #
      # @param data [Hash] The data to decrypt.
      # @return [Hash] The decrypted data, or the original data if it isn't
      #   encrypted.
      # @api private
      def decrypt(data)
        configuration.encryptor.decrypt(data)
      end

      # Sets Sidekiq job options for the requests made in a block.
      #
      # Sidekiq applies the options with its +set+ method, so any job option,
      # such as +queue+ or +retry+, is allowed. A +processor+ option selects the
      # processor profile for the requests instead. Nested blocks merge their
      # options, and the innermost values take precedence. The options apply
      # only to requests made in the same fiber as the block.
      #
      # If the options include a +queue+, the callback job for each request uses
      # that queue as well. Requests made in the block always go through the
      # Sidekiq queue, even when direct execution is enabled, so that Sidekiq
      # applies the options. The options have no effect when jobs run inline
      # with <tt>Sidekiq::Testing.inline!</tt>.
      #
      # @example
      #   PatientHttp::Sidekiq.with_sidekiq_options(queue: "high_priority") do
      #     PatientHttp.get("https://api.example.com/users/123", callback: MyCallback)
      #   end
      #
      # @param options [Hash] The Sidekiq job options, with symbol or string keys.
      # @yield The block in which requests use the options.
      # @return [Object] The return value of the block.
      # @raise [ArgumentError] If +options+ isn't a Hash or no block is given.
      def with_sidekiq_options(options)
        unless options.is_a?(Hash)
          raise ArgumentError.new("options must be a Hash, got: #{options.class}")
        end
        raise ArgumentError.new("with_sidekiq_options requires a block") unless block_given?

        previous = Thread.current[:patient_http_sidekiq_options]
        begin
          Thread.current[:patient_http_sidekiq_options] = (previous || {}).merge(options.transform_keys(&:to_s))
          yield
        ensure
          Thread.current[:patient_http_sidekiq_options] = previous
        end
      end

      # Runs an HTTP request asynchronously and calls the callback service with
      # the result.
      #
      # Application code normally uses the +PatientHttp+ module methods instead,
      # such as +PatientHttp.get+, +PatientHttp.post+, or the
      # PatientHttp::RequestHelper mixin. Those methods take the same options and
      # keep application code independent of the job system. They call this
      # method through the registered request handler.
      #
      # @param request [PatientHttp::Request] The HTTP request.
      # @param callback [Class, String] The callback service class, or its fully
      #   qualified name. The class must define +on_complete+ and +on_error+
      #   instance methods.
      # @param callback_args [#to_h, nil] The arguments to pass to the callback.
      #   Values must be JSON-native types: +nil+, +true+, +false+, String,
      #   Integer, Float, Array, or Hash. Hash keys are converted to strings. The
      #   callback reads the arguments from +response.callback_args+ or
      #   +error.callback_args+ with symbol or string keys.
      # @param raise_error_responses [Boolean, nil] Whether to treat non-2xx
      #   responses as errors and call +on_error+ instead of +on_complete+. If
      #   +nil+, uses the +raise_error_responses+ configuration option.
      # @param processor [Symbol, String, nil] The name of the processor profile
      #   that runs the request. If +nil+, uses the processor set on the request,
      #   then the +processor+ option from {with_sidekiq_options}, then
      #   +:default+.
      # @return [String] The request ID.
      def execute(request, callback:, callback_args: nil, raise_error_responses: nil, processor: nil)
        PatientHttp::CallbackValidator.validate!(callback)
        callback_name = callback.is_a?(Class) ? callback.name : callback.to_s
        callback_args = PatientHttp::CallbackValidator.validate_callback_args(callback_args)
        # The PatientHttp module methods pass nil when the caller did not ask for a
        # specific behavior, so fall back to the configured default the same way the
        # inline handler in the base gem does.
        if raise_error_responses.nil?
          raise_error_responses = configuration.raise_error_responses
        end
        request_id = SecureRandom.uuid

        request_json = request.as_json
        encrypted = encrypt(request_json)

        data = if external_storage.enabled?
          external_storage.store(encrypted, max_size: configuration.payload_store_threshold)
        else
          encrypted
        end

        options = current_sidekiq_options
        processor_name = resolve_processor_name(processor, request, options)
        if options&.any?
          options = options.except("processor")
          queue = options["queue"]
          options = options.merge("patient_http_callback_queue" => queue.to_s) if queue
        end
        args = [data, callback_name, raise_error_responses, callback_args, request_id, processor_name]

        if direct_execution?(options)
          execute_on_local_processor(
            request_json,
            args,
            callback_name: callback_name,
            raise_error_responses: raise_error_responses,
            callback_args: callback_args,
            request_id: request_id,
            processor_name: processor_name
          )
        elsif options&.any?
          RequestWorker.set(options).perform_async(*args)
        else
          RequestWorker.perform_async(*args)
        end

        request_id
      end

      # Registers this gem as the request handler for +PatientHttp+.
      #
      # The gem calls this method when it loads. As a result, the +PatientHttp+
      # module methods work in every process that loads the gem, whether or not
      # the process runs a processor. The handler stays registered for the life
      # of the process. After the processors stop, requests are enqueued in
      # Redis for another process to run.
      #
      # @return [void]
      def register_handler
        @request_handler ||= lambda do |request:, callback:, raise_error_responses:, callback_args:|
          execute(
            request,
            callback: callback,
            raise_error_responses: raise_error_responses,
            callback_args: callback_args
          )
        end

        PatientHttp.register_handler(@request_handler)
      end

      # Starts a processor for each configured processor profile. Also starts
      # the crash-recovery monitor and the stats aggregator that the processors
      # share. The Sidekiq lifecycle hooks call this method when the Sidekiq
      # server starts.
      #
      # @return [void]
      def start
        @lifecycle_mutex.synchronize do
          return if @processors.any? && !@processors.values.all?(&:stopped?)

          warn_about_blocking_redis_driver

          @redis_pool ||= RedisPool.new(configuration)
          @stats ||= Stats.new(configuration)
          @task_monitor ||= TaskMonitor.new(
            configuration,
            processors: -> { processor_capacity_snapshot }
          )

          @processors = {}
          configuration.processor_profiles.each_key do |name|
            processor = PatientHttp::Processor.new(configuration.processor_config(name), name: name)
            processor.observe(ProcessorObserver.new(processor, stats: @stats, task_monitor: @task_monitor))
            configuration.observers.each do |observer|
              processor.observe(observer)
            end
            @processors[name] = processor
          end
          @processors.each_value(&:start)

          # A restart after the processors stopped on their own (e.g. a reactor
          # error) leaves the previous monitor thread running; stop it before
          # replacing the reference so only one thread ever heartbeats.
          @monitor_thread&.stop
          @monitor_thread = TaskMonitorThread.new(
            configuration,
            @task_monitor,
            -> { @processors.values.flat_map(&:tracked_request_ids) },
            stats: @stats
          )
          @monitor_thread.start
        end

        register_handler
      end

      # Drains all processors. A draining processor doesn't accept new requests
      # but continues to run in-flight requests. The Sidekiq lifecycle hooks
      # call this method when Sidekiq receives the quiet signal.
      #
      # @return [void]
      def quiet
        @lifecycle_mutex.synchronize do
          return unless running?

          @processors.each_value(&:drain)
        end
      end

      # Stops all processors and the services they share. The Sidekiq lifecycle
      # hooks call this method when the Sidekiq server shuts down.
      #
      # @param timeout [Float, nil] The maximum number of seconds to wait for
      #   in-flight requests to finish. If +nil+, uses the +shutdown_timeout+
      #   configuration option.
      # @return [void]
      def stop(timeout: nil)
        # The request handler stays registered. A request made while the process
        # is shutting down is enqueued to Redis and run by another process,
        # which is better than raising because no handler is registered.
        @lifecycle_mutex.synchronize do
          # Shared services can outlive the processors when a start failed part
          # way through, so tear them down whenever any of them exist.
          return if @processors.empty? && @redis_pool.nil? && @task_monitor.nil? && @monitor_thread.nil?

          stop_processors(timeout)
          shutdown_shared_services
        end
      end

      # Stops all processors and resets all state. Intended for tests.
      #
      # @return [void]
      # @api private
      def reset!
        @lifecycle_mutex.synchronize do
          stop_processors(0)
          shutdown_shared_services
        end
        @external_storage = nil
        @after_completion_callbacks = []
        @after_error_callbacks = []
        PatientHttp.default_configuration = nil
        # Restore the state a freshly loaded process is in: the handler is
        # registered, the configuration is not built yet.
        register_handler
      end

      # Calls the blocks registered with {after_completion}.
      #
      # @param response [PatientHttp::Response] The HTTP response.
      # @return [void]
      # @api private
      def invoke_completion_callbacks(response)
        @after_completion_callbacks.each do |callback|
          callback.call(response)
        end
      end

      # Calls the blocks registered with {after_error}.
      #
      # @param error [PatientHttp::Error] The error.
      # @return [void]
      # @api private
      def invoke_error_callbacks(error)
        @after_error_callbacks.each do |callback|
          callback.call(error)
        end
      end

      # Returns the processor with the given name.
      #
      # @param name [Symbol, String] The processor name.
      # @return [PatientHttp::Processor, nil] The processor, or +nil+ if no
      #   processor has that name.
      # @api private
      def processor(name = :default)
        @processors[name.to_sym]
      end

      # Sets the default processor. Intended for tests.
      #
      # @param value [PatientHttp::Processor, nil] The processor, or +nil+ to
      #   remove it.
      # @return [void]
      # @api private
      def processor=(value)
        if value.nil?
          @processors.delete(:default)
        else
          @processors[:default] = value
        end
      end

      # Returns the gem's dedicated Redis pool.
      #
      # @return [RedisPool, nil] The pool, or +nil+ if no processor has started
      #   in this process, such as in a web process.
      # @api private
      attr_reader :redis_pool

      # Returns the stats aggregator for this process. The aggregator exists
      # before the processors start, so any code path can record rejected
      # requests.
      #
      # @return [Stats] The stats aggregator.
      # @api private
      def stats
        @stats ||= Stats.new(configuration)
      end

      # Yields a Redis connection from the gem's dedicated pool. Uses Sidekiq's
      # pool if the dedicated pool doesn't exist.
      #
      # @param retry_on_connection_error [Boolean] Whether to run the block
      #   again after a connection failure. Pass +false+ if the block isn't
      #   idempotent, such as a batch of counter increments that the server
      #   might already have applied.
      # @yield [conn] The block that uses the connection.
      # @yieldparam conn [Object] The Redis connection.
      # @return [Object] The return value of the block.
      # @api private
      def redis(retry_on_connection_error: true, &block)
        pool = @redis_pool
        if pool
          pool.with(retry_on_connection_error: retry_on_connection_error, &block)
        else
          ::Sidekiq.redis(&block)
        end
      end

      # Runs a block with Sidekiq client pushes sent through the gem's dedicated
      # Redis pool. Threads that the gem owns, such as the completion workers and
      # the monitor thread, use this method so they don't compete for
      # connections in Sidekiq's internal pool.
      #
      # @yield The block to run.
      # @return [Object] The return value of the block.
      # @api private
      def with_redis_pool(&block)
        pool = @redis_pool&.pool
        if pool
          ::Sidekiq::Client.via(pool, &block)
        else
          yield
        end
      end

      private

      # Returns the capacity of each processor in this process. The monitor
      # thread publishes the snapshot with each heartbeat so that the Web UI can
      # report capacity for each processor. The in-flight count includes every
      # request counted against the processor's capacity: queued, pending, and
      # in flight.
      #
      # @return [Hash{Symbol => Hash}] The +:inflight+ and +:max_capacity+
      #   counts, keyed by processor name.
      def processor_capacity_snapshot
        @processors.each_with_object({}) do |(name, processor), snapshot|
          snapshot[name] = {
            inflight: processor.total_count,
            max_capacity: processor.config.max_connections
          }
        end
      end

      # Stops every processor and clears the registry.
      #
      # Each processor waits up to the full timeout for its in-flight requests,
      # so the processors stop in parallel. Stopping them one at a time would
      # multiply the shutdown time by the number of processors and exceed the
      # time that Sidekiq allows before it ends the process.
      #
      # @param timeout [Float, nil] The maximum number of seconds to wait for
      #   in-flight requests.
      # @return [void]
      def stop_processors(timeout)
        processors = @processors.values
        @processors = {}
        return if processors.empty?

        if processors.size == 1
          processors.first.stop(timeout: timeout)
          return
        end

        processors.map { |processor|
          Thread.new do
            processor.stop(timeout: timeout)
          rescue => e
            configuration.logger&.error(
              "[PatientHttp::Sidekiq] Failed to stop processor #{processor.name}: #{e.inspect}"
            )
          end
        }.each(&:join)
      end

      # Stops the monitor thread, flushes pending stats, removes this process
      # from the registry, and shuts down the Redis pool. The caller must hold
      # the lifecycle mutex and must stop all processors first.
      #
      # @return [void]
      def shutdown_shared_services
        @monitor_thread&.stop
        @monitor_thread = nil
        begin
          @stats&.flush
        rescue => e
          configuration.logger&.error("[PatientHttp::Sidekiq] Failed to flush stats during shutdown: #{e.inspect}")
        end
        begin
          @task_monitor&.remove_process
        rescue => e
          configuration.logger&.error("[PatientHttp::Sidekiq] Failed to remove process registration: #{e.inspect}")
        end
        @task_monitor = nil
        @stats = nil
        @redis_pool&.shutdown
        @redis_pool = nil
      end

      # Logs a warning if the hiredis Redis driver is installed. The driver does
      # blocking I/O that doesn't yield to the fiber scheduler, so a Redis call
      # on the reactor thread stalls every in-flight request. The gem makes its
      # own Redis calls on worker threads, but application observers can still
      # call Redis from processor callbacks.
      #
      # @return [void]
      def warn_about_blocking_redis_driver
        return unless defined?(RedisClient) && RedisClient.default_driver.name.to_s.include?("Hiredis")

        configuration.logger&.warn(
          "[PatientHttp::Sidekiq] hiredis-client detected. The hiredis driver performs blocking I/O " \
          "that does not yield to the fiber scheduler. Avoid Redis calls from processor observers " \
          "or callbacks that run on the reactor thread."
        )
      rescue => e
        configuration.logger&.debug("[PatientHttp::Sidekiq] Redis driver check failed: #{e.inspect}")
      end

      # Returns the Sidekiq options set by the enclosing {with_sidekiq_options}
      # block.
      #
      # @return [Hash, nil] The options, or +nil+ outside a block.
      def current_sidekiq_options
        Thread.current[:patient_http_sidekiq_options]
      end

      # Returns the processor profile name for a request. Uses the first of
      # these that is set: the +processor:+ argument, the processor set on the
      # request, the +processor+ option from {with_sidekiq_options}, and
      # +:default+.
      #
      # @param explicit [Symbol, String, nil] The +processor:+ argument.
      # @param request [PatientHttp::Request] The request.
      # @param options [Hash, nil] The options from {with_sidekiq_options}.
      # @return [String] The processor name.
      def resolve_processor_name(explicit, request, options)
        name = explicit || request.processor || options&.[]("processor") || :default
        name.to_s
      end

      # Returns whether a request can go directly to a processor in the current
      # process. Requests made in a {with_sidekiq_options} block always go
      # through the queue so that Sidekiq applies the options. Requests also go
      # through the queue when Sidekiq testing mode is enabled, so that tests
      # see the enqueued jobs.
      #
      # @param options [Hash, nil] The options from {with_sidekiq_options}.
      # @return [Boolean] +true+ if the request can skip the queue.
      def direct_execution?(options)
        return false unless options.nil?
        return false unless configuration.direct_execution?
        return false unless running?
        return false if defined?(::Sidekiq::Testing) && ::Sidekiq::Testing.enabled?

        true
      end

      # Sends a request to a processor in the current process. If the processor
      # can't accept the request because it's at capacity or shutting down,
      # enqueues the request as a RequestWorker job instead. The processor uses
      # the same path to re-enqueue requests when it drains.
      #
      # @param request_json [Hash] The serialized request.
      # @param args [Array] The RequestWorker job arguments.
      # @param callback_name [String] The callback service class name.
      # @param raise_error_responses [Boolean] Whether to treat non-2xx
      #   responses as errors.
      # @param callback_args [Hash, nil] The arguments to pass to the callback.
      # @param request_id [String] The request ID.
      # @param processor_name [String] The name of the processor profile that
      #   runs the request.
      # @return [void]
      def execute_on_local_processor(request_json, args, callback_name:, raise_error_responses:, callback_args:, request_id:, processor_name: "default")
        task_handler = DirectTaskHandler.new(args)

        begin
          # Reload the request from its serialized form so the direct path
          # processes the same reconstructed request a RequestWorker job would.
          RequestExecutor.execute(
            PatientHttp::Request.load(request_json),
            callback: callback_name,
            raise_error_responses: raise_error_responses,
            callback_args: callback_args,
            task_handler: task_handler,
            request_id: request_id,
            processor_name: processor_name
          )
        rescue PatientHttp::NotRunningError, PatientHttp::MaxCapacityError => e
          configuration.logger&.info(
            "[PatientHttp::Sidekiq] Falling back to enqueuing request: #{e.message}"
          )
          task_handler.retry
        end
      end
    end
  end

  # Set up the gem when it loads, so that requests work without a setup step:
  #
  # - Register the request handler, so that PatientHttp.get and the other module
  #   methods work in every process that loads the gem.
  # - Make PatientHttp.configure and PatientHttp.configuration use this gem's
  #   configuration, so that applications don't need to name the integration.
  # - Register the Sidekiq lifecycle hooks that start and stop the processors
  #   with the Sidekiq server.
  PatientHttp::Sidekiq.register_handler
  PatientHttp.register_configuration_provider(PatientHttp::Sidekiq)
  PatientHttp::Sidekiq::LifecycleHooks.register
end
