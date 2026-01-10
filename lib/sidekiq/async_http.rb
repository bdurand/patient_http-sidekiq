# frozen_string_literal: true

require "sidekiq"
require "async"
require "async/http"
require "concurrent-ruby"

# Main module for the Sidekiq Async HTTP gem
module Sidekiq::AsyncHttp
  VERSION = File.read(File.join(__dir__, "../../VERSION")).strip

  # Autoload all components
  autoload :AsyncRequest, "sidekiq/async_http/async_request"
  autoload :HttpRequest, "sidekiq/async_http/http_request"
  autoload :HttpHeaders, "sidekiq/async_http/http_headers"
  autoload :Request, "sidekiq/async_http/request"
  autoload :Response, "sidekiq/async_http/response"
  autoload :Error, "sidekiq/async_http/error"
  autoload :Configuration, "sidekiq/async_http/configuration"
  autoload :Builder, "sidekiq/async_http/configuration"
  autoload :Metrics, "sidekiq/async_http/metrics"
  autoload :ConnectionPool, "sidekiq/async_http/connection_pool"
  autoload :Processor, "sidekiq/async_http/processor"
  autoload :Client, "sidekiq/async_http/client"

  @processor = nil
  @metrics = nil
  @configuration = nil

  class << self
    attr_writer :configuration, :processor, :metrics

    # Configure the gem with a block
    # @yield [Builder] the configuration builder
    # @return [Configuration]
    def configure
      builder = Builder.new
      yield(builder) if block_given?
      @configuration = builder.build
    end

    # Ensure configuration is initialized
    # @return [Configuration]
    def configuration
      @configuration ||= Configuration.new.validate!
    end

    # Reset configuration to defaults (useful for testing)
    # @return [Configuration]
    def reset_configuration!
      @configuration = nil
      configuration
    end

    # Check if the processor is running
    # @return [Boolean]
    def running?
      !!@processor&.running?
    end

    # Ensure processor is initialized
    # @return [Processor]
    def processor
      @processor ||= Processor.new(configuration)
    end

    # Ensure metrics is initialized
    # @return [Metrics]
    def metrics
      @metrics ||= Metrics.new
    end

    # Main public API: enqueue an async HTTP request
    # @param method [Symbol] HTTP method (:get, :post, :put, :patch, :delete, :head, :options)
    # @param url [String] full URL to request
    # @param success_worker [String] worker class name for success callback
    # @param error_worker [String] worker class name for error callback
    # @param headers [Hash] request headers
    # @param body [String, nil] request body
    # @param timeout [Float] request timeout in seconds
    # @param original_args [Array] original job arguments to pass through
    # @param metadata [Hash] arbitrary user data to pass through
    # @return [String] request ID
    def request(method:, url:, success_worker:, error_worker:,
      headers: {}, body: nil, timeout: nil, original_args: [], metadata: {})
      Client.request(
        method: method,
        url: url,
        headers: headers,
        body: body,
        timeout: timeout,
        success_worker: success_worker,
        error_worker: error_worker,
        original_args: original_args,
        metadata: metadata
      )
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

    # Convenience method for HEAD requests
    # @param url [String] full URL to request
    # @param options [Hash] additional options (see #request)
    # @return [String] request ID
    def head(url, **options)
      request(method: :head, url: url, **options)
    end

    # Convenience method for OPTIONS requests
    # @param url [String] full URL to request
    # @param options [Hash] additional options (see #request)
    # @return [String] request ID
    def options(url, **options)
      request(method: :options, url: url, **options)
    end

    # Start the processor
    # @return [void]
    def start!
      processor.start
    end

    # Stop the processor
    # @return [void]
    def shutdown
      processor&.shutdown
    end

    # Reset all state (useful for testing)
    # @return [void]
    def reset!
      @processor&.shutdown
      @processor = nil
      @metrics = nil
      @configuration = nil
    end
  end
end
