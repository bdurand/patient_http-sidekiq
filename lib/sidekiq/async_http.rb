# frozen_string_literal: true

require "sidekiq"
require "async"
require "async/http"
require "concurrent-ruby"
require "json"
require "uri"

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
  autoload :Client, File.join(__dir__, "async_http/client")
  autoload :Configuration, File.join(__dir__, "async_http/configuration")
  autoload :Context, File.join(__dir__, "async_http/context")
  autoload :Error, File.join(__dir__, "async_http/error")
  autoload :HttpHeaders, File.join(__dir__, "async_http/http_headers")
  autoload :Job, File.join(__dir__, "async_http/job")
  autoload :Metrics, File.join(__dir__, "async_http/metrics")
  autoload :Payload, File.join(__dir__, "async_http/payload")
  autoload :Processor, File.join(__dir__, "async_http/processor")
  autoload :Request, File.join(__dir__, "async_http/request")
  autoload :RequestTask, File.join(__dir__, "async_http/request_task")
  autoload :Response, File.join(__dir__, "async_http/response")
  autoload :Stats, File.join(__dir__, "async_http/stats")

  @processor = nil
  @configuration = nil
  @testing = false

  class << self
    attr_writer :configuration, :processor

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

    # Load Web UI extension if Sidekiq::Web is available
    # This is done after all other requires to ensure dependencies are loaded
    #
    # @return [void]
    def load_web_ui
      require_relative "async_http/web_ui" if defined?(Sidekiq::Web)
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

    # Returns the processor instance (internal accessor)
    # @return [Processor, nil]
    # @api private
    attr_reader :processor

    # Returns the metrics from the processor
    # @return [Metrics, nil]
    def metrics
      processor&.metrics
    end

    # Main public API: enqueue an async HTTP request
    # @param method [Symbol] HTTP method (:get, :post, :put, :patch, :delete, :head, :options)
    # @param url [String, URI] full URL to request
    # @param headers [Hash, HttpHeaders] request headers
    # @param body [String, nil] request body
    # @param json [Object, nil] JSON object to serialize as body
    # @param timeout [Float] request timeout in seconds
    # @param connect_timeout [Float, nil] connection open timeout in seconds
    # @param read_timeout [Float, nil] read timeout in seconds
    # @param write_timeout [Float, nil] write timeout in seconds
    # @param sidekiq_job [Sidekiq::Job, nil] the Sidekiq job context for the current worker
    # @param completion_worker [String] worker class name for success callback
    # @param error_worker [String] worker class name for error callback
    # @return [String] request ID
    def request(method:, url:, completion_worker:, headers: {}, body: nil, json: nil,
      timeout: nil, connect_timeout: nil, read_timeout: nil, write_timeout: nil,
      sidekiq_job: nil, error_worker: nil)
      client = Client.new(timeout: timeout, connect_timeout: connect_timeout, read_timeout: read_timeout, write_timeout: write_timeout)
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

    # @api private
    def testing?
      @testing
    end

    # @api private
    def testing=(value)
      @testing = !!value
    end
  end
end
