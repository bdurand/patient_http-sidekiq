# frozen_string_literal: true

require "sidekiq"
require "patient_http"

# This gem provides a mechanism to offload long-running HTTP requests from Sidekiq workers
# to a dedicated async I/O processor running in the same process, freeing worker threads
# immediately while HTTP requests are in flight.
#
# == Usage
#
# Make HTTP requests from anywhere in your code:
#
#   request = PatientHttp::Request.new(:get, "https://api.example.com/users/123")
#   PatientHttp::Sidekiq.execute(
#     request,
#     callback: MyCallback,
#     callback_args: {user_id: 123}
#   )
#
# Set Sidekiq job options at runtime for the requests enqueued within a block:
#
#   PatientHttp::Sidekiq.with_sidekiq_options(queue: "high_priority") do
#     PatientHttp::Sidekiq.execute(request, callback: MyCallback)
#   end
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
# == Key Features
#
# - Asynchronous HTTP processing using Ruby's Fiber scheduler
# - Non-blocking worker threads
# - Automatic connection pooling and HTTP/2 support
# - Comprehensive error handling and retry logic
# - Integration with Sidekiq's job lifecycle
# - Optional Web UI for monitoring
#
# = Singleton Processor Pattern
#
# This module maintains a single Processor instance at the module level (@processor).
# This is an intentional design decision driven by integration requirements with Sidekiq's
# lifecycle and practical operational considerations:
#
# == Rationale:
#
# 1. **Sidekiq Integration**: The processor lifecycle (start/quiet/stop) must align with
#    Sidekiq's own lifecycle hooks. A single processor instance integrates cleanly with
#    Sidekiq's startup and shutdown signals.
#
# 2. **Resource Management**: Running multiple async I/O reactors in a single process would
#    create resource contention and complexity. A single reactor efficiently handles all
#    HTTP requests using connection pooling and fiber-based concurrency.
#
# 3. **Configuration Simplicity**: A singleton processor means one configuration, one set
#    of metrics, and one connection pool. Multiple processors would require complex
#    coordination and resource allocation.
#
# 4. **Process Model**: Sidekiq's process model (multiple workers, single process) maps
#    naturally to a single async processor per process. Each Sidekiq process gets one
#    processor, workers within that process share it.
module PatientHttp
  module Sidekiq
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
    @configuration = nil
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
      attr_writer :configuration

      # Configure the gem with a block. The built configuration is also set as the
      # `PatientHttp.default_configuration` so that secrets registered at the module
      # level with `PatientHttp.register_secret` are applied to the configuration the
      # processor runs with, regardless of boot order.
      #
      # @yield [Configuration] the configuration object
      # @return [Configuration]
      def configure
        configuration = Configuration.new
        yield(configuration) if block_given?
        @configuration = configuration
        @external_storage = nil
        # Rebuild the stats aggregator from the new configuration unless a
        # running processor already owns it.
        @stats = nil unless running?
        register_handler
        PatientHttp.default_configuration = configuration
        configuration
      end

      # Ensure configuration is initialized
      # @return [Configuration]
      def configuration
        @configuration ||= Configuration.new
      end

      # Reset configuration to defaults (useful for testing)
      # @return [Configuration]
      def reset_configuration!
        @configuration = nil
        @external_storage = nil
        configuration
      end

      # Add a callback to be executed after a successful request completion.
      #
      # @yield [response] block to execute after an HTTP request completes
      # @yieldparam response [PatientHttp::Response] the HTTP response
      def after_completion(&block)
        @after_completion_callbacks << block
      end

      # Add a callback to be executed after a request error.
      #
      # @yield [error] block to execute after an HTTP request errors
      # @yieldparam error [PatientHttp::Error] information about the error that was raised
      def after_error(&block)
        @after_error_callbacks << block
      end

      # Add Sidekiq middleware for context handling. The middleware
      # is already added during initialization. You can call this method again to
      # append the middleware if needed to insert it after other middleware. If you need
      # further control, you can manually add the `PatientHttp::Sidekiq::Context::Middleware`
      # middleware yourself.
      #
      # @return [void]
      def append_middleware
        ::Sidekiq.configure_server do |config|
          config.server_middleware do |chain|
            chain.add PatientHttp::Sidekiq::Context::Middleware
          end
        end
      end

      # Check if any processor is running.
      #
      # @return [Boolean]
      def running?
        @processors.values.any?(&:running?)
      end

      # Check if any processor is draining (not accepting new requests
      # but still processing in-flight ones).
      #
      # @return [Boolean]
      def draining?
        @processors.values.any?(&:draining?)
      end

      # Check if any processor is in the process of stopping.
      #
      # @return [Boolean]
      def stopping?
        @processors.values.any?(&:stopping?)
      end

      # Check if all processors are stopped or none have been started.
      #
      # @return [Boolean]
      def stopped?
        @processors.values.all?(&:stopped?)
      end

      # Get an ExternalStorage instance for storing and fetching payloads.
      #
      # @return [PatientHttp::ExternalStorage]
      # @api private
      def external_storage
        @external_storage ||= PatientHttp::ExternalStorage.new(configuration)
      end

      # Encrypt data using the configured encryptor.
      #
      # @param data [Hash] the data to encrypt
      # @return [Hash] the encrypted data (or original if no encryption configured)
      # @api private
      def encrypt(data)
        configuration.encryptor.encrypt(data)
      end

      # Decrypt data using the configured encryptor.
      #
      # @param data [Hash] the data to decrypt
      # @return [Hash] the decrypted data (or original if not encrypted)
      # @api private
      def decrypt(data)
        configuration.encryptor.decrypt(data)
      end

      # Set Sidekiq job options for HTTP requests enqueued within the block.
      # Options are applied with Sidekiq's `set` method (queue, retry, etc.).
      # Nested calls merge options with the innermost values taking precedence.
      # If the options include a queue, the callback job for the request is
      # enqueued on that queue as well. Options only apply to requests enqueued
      # in the same fiber as the block. Requests made in the block always go
      # through the Sidekiq queue, even when direct execution is enabled, so
      # that Sidekiq applies the options. This method has no effect
      # when jobs run inline with Sidekiq::Testing.inline!.
      #
      # @param options [Hash] Sidekiq job options (symbol or string keys)
      # @yield block within which enqueued requests use the options
      # @return [Object] the return value of the block
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

      # Execute an async HTTP request.
      #
      # @param request [PatientHttp::Request] the HTTP request to execute
      # @param callback [Class, String] Callback service class with +on_complete+ and +on_error+
      #   instance methods, or its fully qualified class name.
      # @param callback_args [#to_h, nil] Arguments to pass to callback via the
      #   PatientHttp::Response/PatientHttp::Error object. Must respond to +to_h+ and contain only JSON-native types
      #   (nil, true, false, String, Integer, Float, Array, Hash). All hash keys will be
      #   converted to strings for serialization. Access via +response.callback_args+ or
      #   +error.callback_args+ using symbol or string keys.
      # @param raise_error_responses [Boolean] If true, treats non-2xx responses as errors
      #   and calls +on_error+ instead of +on_complete+. Defaults to false.
      # @param processor [Symbol, String, nil] Name of the processor profile that should
      #   execute the request. Defaults to the request's own processor name, a
      #   "processor" value from with_sidekiq_options, or :default.
      # @return [String] the request ID
      def execute(request, callback:, callback_args: nil, raise_error_responses: false, processor: nil)
        PatientHttp::CallbackValidator.validate!(callback)
        callback_name = callback.is_a?(Class) ? callback.name : callback.to_s
        callback_args = PatientHttp::CallbackValidator.validate_callback_args(callback_args)
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

      # Register Sidekiq as the request handler for processing HTTP requests. This is called
      # automatically when the processor starts or you call PatientHttp::Sidekiq.configure.
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

      # Start a processor for each configured processor profile, along with the
      # shared crash-recovery monitor and stats.
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

      # Signal all processors to drain (stop accepting new requests)
      #
      # @return [void]
      def quiet
        @lifecycle_mutex.synchronize do
          return unless running?

          @processors.each_value(&:drain)
        end
      end

      # Stop all processors gracefully
      #
      # @param timeout [Float, nil] maximum time to wait for in-flight requests to complete
      # @return [void]
      def stop(timeout: nil)
        if @request_handler
          PatientHttp.unregister_handler(@request_handler)
        end

        @lifecycle_mutex.synchronize do
          # Shared services can outlive the processors when a start failed part
          # way through, so tear them down whenever any of them exist.
          return if @processors.empty? && @redis_pool.nil? && @task_monitor.nil? && @monitor_thread.nil?

          stop_processors(timeout)
          shutdown_shared_services
        end
      end

      # Reset all state (useful for testing)
      #
      # @return [void]
      # @api private
      def reset!
        @lifecycle_mutex.synchronize do
          stop_processors(0)
          shutdown_shared_services
        end
        @configuration = nil
        @external_storage = nil
        @after_completion_callbacks = []
        @after_error_callbacks = []
        PatientHttp.unregister_handler(@request_handler) if @request_handler
      end

      # Invoke the registered completion callbacks
      #
      # @param response [PatientHttp::Response] the HTTP response
      # @return [void]
      # @api private
      def invoke_completion_callbacks(response)
        @after_completion_callbacks.each do |callback|
          callback.call(response)
        end
      end

      # Invoke the registered error callbacks
      #
      # @param error [PatientHttp::Error] information about the error that was raised
      # @return [void]
      # @api private
      def invoke_error_callbacks(error)
        @after_error_callbacks.each do |callback|
          callback.call(error)
        end
      end

      # Returns a processor instance by name (internal accessor).
      #
      # @param name [Symbol, String] the processor name
      # @return [PatientHttp::Processor, nil]
      # @api private
      def processor(name = :default)
        @processors[name.to_sym]
      end

      # Set the default processor (internal, for testing).
      #
      # @param value [PatientHttp::Processor, nil]
      # @api private
      def processor=(value)
        if value.nil?
          @processors.delete(:default)
        else
          @processors[:default] = value
        end
      end

      # The gem's dedicated Redis pool, or nil when no processor has started
      # in this process (e.g. web or client processes).
      #
      # @return [RedisPool, nil]
      # @api private
      attr_reader :redis_pool

      # The shared stats aggregator for this process. Available before start so
      # rejection stats can be recorded from any path.
      #
      # @return [Stats]
      # @api private
      def stats
        @stats ||= Stats.new(configuration)
      end

      # Yield a Redis connection: the gem's dedicated pool when it exists,
      # falling back to Sidekiq's pool selection otherwise.
      #
      # @param retry_on_connection_error [Boolean] whether a connection-level
      #   failure may replay the block. Pass false when the block is not
      #   idempotent, such as a batch of counter increments the server may
      #   already have applied.
      # @yield [conn] the Redis connection
      # @return [Object] the block's return value
      # @api private
      def redis(retry_on_connection_error: true, &block)
        pool = @redis_pool
        if pool
          pool.with(retry_on_connection_error: retry_on_connection_error, &block)
        else
          ::Sidekiq.redis(&block)
        end
      end

      # Run a block with Sidekiq client pushes routed through the gem's
      # dedicated Redis pool. Used for pushes made from gem-owned threads
      # (completion workers, the monitor thread) so they do not contend with
      # Sidekiq's internal pool.
      #
      # @return [Object] the block's return value
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

      # Snapshot of each processor's capacity in this process, published with
      # the heartbeat so the Web UI can report capacity per processor. The
      # inflight count is the number of requests counted against the
      # processor's capacity: queued, pending, and in flight.
      #
      # @return [Hash] processor name => { inflight:, max_capacity: }
      def processor_capacity_snapshot
        @processors.each_with_object({}) do |(name, processor), snapshot|
          snapshot[name] = {
            inflight: processor.total_count,
            max_capacity: processor.config.max_connections
          }
        end
      end

      # Stop every processor and clear the registry. Each processor waits up to
      # the full timeout for its in-flight requests, so they are stopped in
      # parallel; stopping them in sequence would multiply the shutdown
      # deadline by the number of processor profiles and overrun the time
      # Sidekiq allows before it kills the process.
      #
      # @param timeout [Float, nil] maximum time to wait for in-flight requests
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

      # Stop the shared monitor thread, flush pending stats, remove this
      # process from the registry, and shut down the Redis pool. Called with
      # the lifecycle mutex held after all processors have stopped.
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

      # Log a warning when a blocking C-level Redis driver is installed.
      # Blocking Redis I/O on the reactor thread stalls every in-flight HTTP
      # request; the gem's own calls run on worker threads, but application
      # observers may still call Redis from processor callbacks.
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

      # Current scoped Sidekiq options, if any.
      #
      # @return [Hash, nil]
      def current_sidekiq_options
        Thread.current[:patient_http_sidekiq_options]
      end

      # Resolve the processor profile name for a request. Precedence: the
      # explicit +processor:+ argument, the request's own processor name, a
      # "processor" value from with_sidekiq_options, then :default.
      #
      # @param explicit [Symbol, String, nil] the processor: argument
      # @param request [PatientHttp::Request] the request
      # @param options [Hash, nil] scoped Sidekiq options
      # @return [String] the processor name
      def resolve_processor_name(explicit, request, options)
        name = explicit || request.processor || options&.[]("processor") || :default
        name.to_s
      end

      # Check if the request can go directly to a processor running in the current
      # process. Requests made in a with_sidekiq_options block always go through
      # the queue so that Sidekiq applies the options (queue routing, scheduling,
      # retry), and Sidekiq testing modes must keep their normal enqueue semantics.
      #
      # @param options [Hash, nil] scoped Sidekiq options for the request
      # @return [Boolean]
      def direct_execution?(options)
        return false unless options.nil?
        return false unless configuration.direct_execution?
        return false unless running?
        return false if defined?(::Sidekiq::Testing) && ::Sidekiq::Testing.enabled?

        true
      end

      # Hand the request to the processor running in the current process. If the
      # processor cannot accept the request (at capacity or shutting down), the
      # request is enqueued as a normal RequestWorker job instead through the
      # same retry path the processor uses when it drains.
      #
      # @param request_json [Hash] the serialized request
      # @param args [Array] the RequestWorker job arguments
      # @param callback_name [String] the callback service class name
      # @param raise_error_responses [Boolean] whether non-2xx responses are errors
      # @param callback_args [Hash, nil] arguments to pass to the callback
      # @param request_id [String] unique request ID
      # @param processor_name [String] name of the processor profile to run on
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

  PatientHttp::Sidekiq::LifecycleHooks.register
end
