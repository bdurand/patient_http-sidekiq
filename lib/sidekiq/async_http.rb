# frozen_string_literal: true

require "sidekiq"
require "async"
require "async/http"
require "concurrent-ruby"
require "json"
require "uri"
require "zlib"
require "time"
require "socket"

# Main module for the Sidekiq Async HTTP gem.
#
# This gem provides a mechanism to offload long-running HTTP requests from Sidekiq workers
# to a dedicated async I/O processor running in the same process, freeing worker threads
# immediately while HTTP requests are in flight.
#
# == Usage
#
# Make HTTP requests from anywhere in your code:
#
#   Sidekiq::AsyncHttp.get(
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
  autoload :AsyncHttpClient, File.join(__dir__, "async_http/async_http_client")
  autoload :CallbackArgs, File.join(__dir__, "async_http/callback_args")
  autoload :CallbackWorker, File.join(__dir__, "async_http/callback_worker")
  autoload :Client, File.join(__dir__, "async_http/client")
  autoload :ClientPool, File.join(__dir__, "async_http/client_pool")
  autoload :Configuration, File.join(__dir__, "async_http/configuration")
  autoload :Context, File.join(__dir__, "async_http/context")
  autoload :Error, File.join(__dir__, "async_http/error")
  autoload :ExternalStorage, File.join(__dir__, "async_http/external_storage")
  autoload :HttpError, File.join(__dir__, "async_http/http_error")
  autoload :ClientError, File.join(__dir__, "async_http/http_error")
  autoload :ServerError, File.join(__dir__, "async_http/http_error")
  autoload :RedirectError, File.join(__dir__, "async_http/redirect_error")
  autoload :TooManyRedirectsError, File.join(__dir__, "async_http/redirect_error")
  autoload :RecursiveRedirectError, File.join(__dir__, "async_http/redirect_error")
  autoload :RequestError, File.join(__dir__, "async_http/request_error")
  autoload :RequestWorker, File.join(__dir__, "async_http/request_worker")
  autoload :HttpHeaders, File.join(__dir__, "async_http/http_headers")
  autoload :InflightRegistry, File.join(__dir__, "async_http/inflight_registry")
  autoload :MonitorThread, File.join(__dir__, "async_http/monitor_thread")
  autoload :Payload, File.join(__dir__, "async_http/payload")

  # PayloadStore module for external storage adapters
  module PayloadStore
    autoload :Base, File.join(__dir__, "async_http/payload_store/base")
    autoload :FileStore, File.join(__dir__, "async_http/payload_store/file_store")
  end
  autoload :LifecycleManager, File.join(__dir__, "async_http/lifecycle_manager")
  autoload :Processor, File.join(__dir__, "async_http/processor")
  autoload :Request, File.join(__dir__, "async_http/request")
  autoload :RequestTask, File.join(__dir__, "async_http/request_task")
  autoload :Response, File.join(__dir__, "async_http/response")
  autoload :ResponseReader, File.join(__dir__, "async_http/response_reader")
  autoload :SidekiqLifecycleHooks, File.join(__dir__, "async_http/sidekiq_lifecycle_hooks")
  autoload :Stats, File.join(__dir__, "async_http/stats")
  autoload :SynchronousExecutor, File.join(__dir__, "async_http/synchronous_executor")

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

    # Add Sidekiq middleware for context handling. The middleware
    # is already added during initialization. You can call this method again to
    # append the middleware if needed to insert it after other middleware. If you need
    # further control, you can manually add the `Sidekiq::AsyncHttp::Context::Middleware`
    # middleware yourself.
    #
    # @return [void]
    def append_middleware
      Sidekiq.configure_server do |config|
        config.server_middleware do |chain|
          chain.add Sidekiq::AsyncHttp::Context::Middleware
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

    # Enqueue an async HTTP request.
    #
    # @param method [Symbol] HTTP method (:get, :post, :put, :patch, :delete)
    # @param url [String, URI] full URL to request
    # @param callback [Class, String] callback service class with on_complete and on_error instance methods
    # @param headers [Hash, HttpHeaders] request headers
    # @param body [String, nil] request body
    # @param json [Object, nil] JSON object to serialize as body
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
      timeout: nil,
      raise_error_responses: nil,
      callback_args: nil
    )
      client = Client.new(timeout: timeout)
      request = client.async_request(method, url, body: body, json: json, headers: headers)
      request.async_execute(
        callback: callback,
        raise_error_responses: raise_error_responses,
        callback_args: callback_args
      )
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

    # Check if running in testing mode.
    #
    # @api private
    def testing?
      @testing
    end

    # Set testing mode. This should only be set in testing environments.
    #
    # @api private
    def testing=(value)
      @testing = !!value
    end

    # Returns the processor instance (internal accessor)
    #
    # @return [Processor, nil]
    # @api private
    attr_accessor :processor
  end
end

Sidekiq::AsyncHttp::SidekiqLifecycleHooks.register
