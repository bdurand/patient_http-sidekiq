# frozen_string_literal: true

require "sidekiq"
require "async"
require "async/http"
require "concurrent-ruby"
require "json"
require "uri"
require "zlib"

# Main module for the Sidekiq Async HTTP gem.
#
# This gem provides a mechanism to offload long-running HTTP requests from Sidekiq workers
# to a dedicated async I/O processor running in the same process, freeing worker threads
# immediately while HTTP requests are in flight.
#
# Key features:
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
module Sidekiq::AsyncHttp
  # Raised when trying to enqueue a request when the processor is not running
  class NotRunningError < StandardError; end

  class MaxCapacityError < StandardError; end

  class ResponseTooLargeError < StandardError; end

  VERSION = File.read(File.join(__dir__, "../../VERSION")).strip

  # Autoload utility modules
  autoload :ClassHelper, File.join(__dir__, "async_http/class_helper")
  autoload :TimeHelper, File.join(__dir__, "async_http/time_helper")

  # Autoload all components
  autoload :CallbackArgs, File.join(__dir__, "async_http/callback_args")
  autoload :Client, File.join(__dir__, "async_http/client")
  autoload :Configuration, File.join(__dir__, "async_http/configuration")
  autoload :Context, File.join(__dir__, "async_http/context")
  autoload :ContinuationMiddleware, File.join(__dir__, "async_http/continuation_middleware")
  autoload :Error, File.join(__dir__, "async_http/error")
  autoload :HttpError, File.join(__dir__, "async_http/error")
  autoload :ClientError, File.join(__dir__, "async_http/error")
  autoload :ServerError, File.join(__dir__, "async_http/error")
  autoload :RequestError, File.join(__dir__, "async_http/error")
  autoload :HttpClientFactory, File.join(__dir__, "async_http/http_client_factory")
  autoload :HttpHeaders, File.join(__dir__, "async_http/http_headers")
  autoload :InflightRegistry, File.join(__dir__, "async_http/inflight_registry")
  autoload :InlineRequest, File.join(__dir__, "async_http/inline_request")
  autoload :Job, File.join(__dir__, "async_http/job")
  autoload :Metrics, File.join(__dir__, "async_http/metrics")
  autoload :MonitorThread, File.join(__dir__, "async_http/monitor_thread")
  autoload :Payload, File.join(__dir__, "async_http/payload")
  autoload :LifecycleManager, File.join(__dir__, "async_http/lifecycle_manager")
  autoload :Processor, File.join(__dir__, "async_http/processor")
  autoload :Request, File.join(__dir__, "async_http/request")
  autoload :RequestBuilder, File.join(__dir__, "async_http/request_builder")
  autoload :RequestTask, File.join(__dir__, "async_http/request_task")
  autoload :Response, File.join(__dir__, "async_http/response")
  autoload :ResponseReader, File.join(__dir__, "async_http/response_reader")
  autoload :SidekiqLifecycleHooks, File.join(__dir__, "async_http/sidekiq_lifecycle_hooks")
  autoload :SerializeResponseMiddleware, File.join(__dir__, "async_http/serialize_response_middleware")
  autoload :Stats, File.join(__dir__, "async_http/stats")

  @processor = nil
  @configuration = nil
  @after_completion_callbacks = []
  @after_error_callbacks = []
  @testing = false

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
    # @yieldparam response [Response] the HTTP response
    def after_completion(&block)
      @after_completion_callbacks << block
    end

    # Add a callback to be executed after a request error.
    #
    # @yield [error] block to execute after an HTTP request errors
    # @yieldparam error [Error] information about the error that was raised
    def after_error(&block)
      @after_error_callbacks << block
    end

    # Add Sidekiq middleware for context and continuation handling. The middleware
    # is already added during initialization. You can call this method again to
    # append the middleware if needed to insert it after other middleware. If you need
    # further control, you can manually add the `Sidekiq::AsyncHttp::Context::Middleware`
    # and `Sidekiq::AsyncHttp::ContinuationMiddleware` middleware yourself.
    #
    # @return [void]
    def append_middleware
      Sidekiq.configure_client do |config|
        config.client_middleware do |chain|
          chain.prepend Sidekiq::AsyncHttp::SerializeResponseMiddleware
        end
      end

      Sidekiq.configure_server do |config|
        config.client_middleware do |chain|
          chain.prepend Sidekiq::AsyncHttp::SerializeResponseMiddleware
        end

        config.server_middleware do |chain|
          chain.add Sidekiq::AsyncHttp::Context::Middleware
          chain.add Sidekiq::AsyncHttp::ContinuationMiddleware
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

    # Main public API: enqueue an async HTTP request
    # @param method [Symbol] HTTP method (:get, :post, :put, :patch, :delete, :head, :options)
    # @param url [String, URI] full URL to request
    # @param headers [Hash, HttpHeaders] request headers
    # @param body [String, nil] request body
    # @param json [Object, nil] JSON object to serialize as body
    # @param timeout [Float] request timeout in seconds
    # @param connect_timeout [Float, nil] connection open timeout in seconds
    # @param sidekiq_job [Sidekiq::Job, nil] the Sidekiq job context for the current worker
    # @param completion_worker [String] worker class name for success callback
    # @param error_worker [String] worker class name for error callback
    # @return [String] request ID
    def request(method:, url:, completion_worker:, headers: {}, body: nil, json: nil,
      timeout: nil, connect_timeout: nil,
      sidekiq_job: nil, error_worker: nil)
      client = Client.new(timeout: timeout, connect_timeout: connect_timeout)
      request = client.async_request(method, url, body: body, json: json, headers: headers)
      request.execute(sidekiq_job: sidekiq_job, completion_worker_class: completion_worker, error_worker_class: error_worker)
      request.id
    end

    # Convenience method for GET requests
    # @param url [String] full URL to request
    # @param options [Hash] additional options (see #request)
    # @return [String] request ID
    def get(url, **options)
      request(method: :get, url: url, **options)
    end

    # Convenience method for POST requests
    # @param url [String] full URL to request
    # @param options [Hash] additional options (see #request)
    # @return [String] request ID
    def post(url, **options)
      request(method: :post, url: url, **options)
    end

    # Convenience method for PUT requests
    # @param url [String] full URL to request
    # @param options [Hash] additional options (see #request)
    # @return [String] request ID
    def put(url, **options)
      request(method: :put, url: url, **options)
    end

    # Convenience method for PATCH requests
    # @param url [String] full URL to request
    # @param options [Hash] additional options (see #request)
    # @return [String] request ID
    def patch(url, **options)
      request(method: :patch, url: url, **options)
    end

    # Convenience method for DELETE requests
    # @param url [String] full URL to request
    # @param options [Hash] additional options (see #request)
    # @return [String] request ID
    def delete(url, **options)
      request(method: :delete, url: url, **options)
    end

    # Start the processor
    #
    # @return [void]
    def start
      return if running?

      @processor = Processor.new(configuration)
      @processor.start
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
    end

    # Invoke the registered completion callbacks
    #
    # @param response [Response] the HTTP response
    # @return [void]
    # @api private
    def invoke_completion_callbacks(response)
      @after_completion_callbacks.each do |callback|
        callback.call(response)
      end
    end

    # Invoke the registered error callbacks
    #
    # @param error [Error] information about the error that was raised
    # @return [void]
    # @api private
    def invoke_error_callbacks(error)
      @after_error_callbacks.each do |callback|
        callback.call(error)
      end
    end

    # @api private
    def testing?
      @testing
    end

    # @api private
    def testing=(value)
      @testing = !!value
    end

    # Returns the processor instance (internal accessor)
    # @return [Processor, nil]
    # @api private
    attr_accessor :processor

    # Returns the metrics from the processor
    # @return [Metrics, nil]
    def metrics
      processor&.metrics
    end
  end
end

Sidekiq::AsyncHttp::SidekiqLifecycleHooks.register
