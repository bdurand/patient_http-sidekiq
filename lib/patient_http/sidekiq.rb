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
#   PatientHttp::Sidekiq.get(
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
    autoload :ProcessorObserver, File.join(__dir__, "sidekiq/processor_observer")
    autoload :RequestExecutor, File.join(__dir__, "sidekiq/request_executor")
    autoload :RequestWorker, File.join(__dir__, "sidekiq/request_worker")
    autoload :LifecycleHooks, File.join(__dir__, "sidekiq/lifecycle_hooks")
    autoload :TaskHandler, File.join(__dir__, "sidekiq/task_handler")
    autoload :Stats, File.join(__dir__, "sidekiq/stats")
    autoload :TaskMonitor, File.join(__dir__, "sidekiq/task_monitor")
    autoload :TaskMonitorThread, File.join(__dir__, "sidekiq/task_monitor_thread")
    autoload :WebUI, File.join(__dir__, "sidekiq/web_ui")

    @processor = nil
    @configuration = nil
    @after_completion_callbacks = []
    @after_error_callbacks = []
    @external_storage = nil
    @request_handler = nil

    class << self
      attr_writer :configuration

      # Configure the gem with a block
      # @yield [Configuration] the configuration object
      # @return [Configuration]
      def configure
        configuration = Configuration.new
        yield(configuration) if block_given?
        @configuration = configuration
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

      # Check if the processor is running
      # @return [Boolean]
      def running?
        !!@processor&.running?
      end

      def draining?
        !!@processor&.draining?
      end

      def stopping?
        !!@processor&.stopping?
      end

      def stopped?
        @processor.nil? || @processor.stopped?
      end

      # Get an ExternalStorage instance for storing and fetching payloads.
      #
      # @return [PatientHttp::ExternalStorage]
      # @api private
      def external_storage
        @external_storage ||= PatientHttp::ExternalStorage.new(configuration)
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
      # @return [String] the request ID
      def execute(request, callback:, callback_args: nil, raise_error_responses: false)
        PatientHttp::CallbackValidator.validate!(callback)
        callback_name = callback.is_a?(Class) ? callback.name : callback.to_s
        callback_args = PatientHttp::CallbackValidator.validate_callback_args(callback_args)
        request_id = SecureRandom.uuid

        encrypted = configuration.encrypt(request.as_json)

        data = if external_storage.enabled?
          external_storage.store(encrypted, max_size: configuration.payload_store_threshold)
        else
          encrypted
        end

        RequestWorker.perform_async(data, callback_name, raise_error_responses, callback_args, request_id)

        request_id
      end

      # Enqueue an async HTTP request.
      #
      # @param method [Symbol] HTTP method (:get, :post, :put, :patch, :delete)
      # @param url [String, URI] full URL to request
      # @param callback [Class, String] callback service class with on_complete and on_error instance methods
      # @param headers [Hash, PatientHttp::HttpHeaders] request headers
      # @param body [String, nil] request body
      # @param json [Object, nil] JSON object to serialize as body
      # @param params [Hash, nil] query parameters to append to URL
      # @param timeout [Float] request timeout in seconds
      # @param raise_error_responses [Boolean, nil] treat non-2xx responses as errors
      # @param callback_args [Hash, nil] arguments to pass to callback via response/error
      # @return [String] request ID
      def request(
        method,
        url,
        callback:,
        headers: {},
        body: nil,
        json: nil,
        params: nil,
        timeout: nil,
        raise_error_responses: nil,
        callback_args: nil
      )
        request = PatientHttp::Request.new(method, url, body: body, json: json, headers: headers, params: params, timeout: timeout)
        execute(request, callback: callback, raise_error_responses: raise_error_responses, callback_args: callback_args)
      end

      # Convenience method for GET requests
      # @param url [String] full URL to request
      # @param callback [Class, String] callback service class with on_complete and on_error instance methods
      # @param options [Hash] additional options (see #request)
      # @return [String] request ID
      def get(url, callback:, **options)
        request(:get, url, callback: callback, **options)
      end

      # Convenience method for POST requests
      # @param url [String] full URL to request
      # @param callback [Class, String] callback service class with on_complete and on_error instance methods
      # @param options [Hash] additional options (see #request)
      # @return [String] request ID
      def post(url, callback:, **options)
        request(:post, url, callback: callback, **options)
      end

      # Convenience method for PUT requests
      # @param url [String] full URL to request
      # @param callback [Class, String] callback service class with on_complete and on_error instance methods
      # @param options [Hash] additional options (see #request)
      # @return [String] request ID
      def put(url, callback:, **options)
        request(:put, url, callback: callback, **options)
      end

      # Convenience method for PATCH requests
      # @param url [String] full URL to request
      # @param callback [Class, String] callback service class with on_complete and on_error instance methods
      # @param options [Hash] additional options (see #request)
      # @return [String] request ID
      def patch(url, callback:, **options)
        request(:patch, url, callback: callback, **options)
      end

      # Convenience method for DELETE requests
      # @param url [String] full URL to request
      # @param callback [Class, String] callback service class with on_complete and on_error instance methods
      # @param options [Hash] additional options (see #request)
      # @return [String] request ID
      def delete(url, callback:, **options)
        request(:delete, url, callback: callback, **options)
      end

      # Start the processor
      #
      # @return [void]
      def start
        return if running?

        @processor = PatientHttp::Processor.new(configuration)
        @processor.observe(ProcessorObserver.new(@processor))
        @processor.start

        @request_handler ||= lambda do |request:, callback:, raise_error_responses:, callback_args:|
          execute(
            request,
            callback: callback,
            raise_error_responses: raise_error_responses,
            callback_args: callback_args
          )
        end

        PatientHttp::RequestHelper.register_handler(@request_handler)
      end

      # Signal the processor to drain (stop accepting new requests)
      #
      # @return [void]
      def quiet
        return unless running?

        @processor.drain
      end

      # Stop the processor gracefully
      #
      # @param timeout [Float, nil] maximum time to wait for in-flight requests to complete
      # @return [void]
      def stop(timeout: nil)
        return unless @processor

        timeout ||= configuration.shutdown_timeout
        @processor.stop(timeout: timeout)

        if @request_handler
          PatientHttp::RequestHelper.unregister_handler(@request_handler)
        end

        @processor = nil
      end

      # Reset all state (useful for testing)
      #
      # @return [void]
      # @api private
      def reset!
        @processor&.stop(timeout: 0)
        @processor = nil
        @configuration = nil
        @external_storage = nil
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

      # Returns the processor instance (internal accessor)
      #
      # @return [PatientHttp::Processor, nil]
      # @api private
      attr_accessor :processor
    end
  end

  PatientHttp::Sidekiq::LifecycleHooks.register
end
