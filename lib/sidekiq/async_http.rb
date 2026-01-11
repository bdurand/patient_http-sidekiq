# frozen_string_literal: true

require "sidekiq"
require "async"
require "async/http"
require "concurrent-ruby"

# Main module for the Sidekiq Async HTTP gem
module Sidekiq::AsyncHttp
  # Raised when trying to enqueue a request when the processor is not running
  class NotRunningError < StandardError; end

  VERSION = File.read(File.join(__dir__, "../../VERSION")).strip

  require_relative "async_http/time_helper"

  # Autoload all components
  autoload :Client, "sidekiq/async_http/client"
  autoload :Configuration, "sidekiq/async_http/configuration"
  autoload :ConnectionPool, "sidekiq/async_http/connection_pool"
  autoload :Error, "sidekiq/async_http/error"
  autoload :HttpHeaders, "sidekiq/async_http/http_headers"
  autoload :Metrics, "sidekiq/async_http/metrics"
  autoload :Processor, "sidekiq/async_http/processor"
  autoload :Request, "sidekiq/async_http/request"
  autoload :RequestTask, "sidekiq/async_http/request_task"
  autoload :Response, "sidekiq/async_http/response"

  @processor = nil
  @configuration = nil

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

    # Check if the processor is running
    # @return [Boolean]
    def running?
      !!@processor&.running?
    end

    # Returns the processor instance (internal accessor)
    # @return [Processor, nil]
    # @api private
    def processor
      @processor
    end

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
    # @param open_timeout [Float, nil] connection open timeout in seconds
    # @param read_timeout [Float, nil] read timeout in seconds
    # @param write_timeout [Float, nil] write timeout in seconds
    # @param sidekiq_job [Sidekiq::Job, nil] the Sidekiq job context for the current worker
    # @param success_worker [String] worker class name for success callback
    # @param error_worker [String] worker class name for error callback
    # @return [String] request ID
    def request(method:, url:, headers: {}, body: nil, json: nil,
      timeout: nil, open_timeout: nil, read_timeout: nil, write_timeout: nil,
      sidekiq_job: nil, success_worker:, error_worker: nil)
      client = Client.new(timeout: timeout, open_timeout: open_timeout, read_timeout: read_timeout, write_timeout: write_timeout)
      request = client.async_request(method, url, body: body, json: json, headers: headers)
      request.perform(sidekiq_job: sidekiq_job, success_worker_class: success_worker, error_worker_class: error_worker)
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
    # @return [void]
    def start!
      @processor ||= Processor.new(configuration)
      @processor.start
    end

    # Stop the processor
    # @return [void]
    def shutdown
      @processor&.stop
    end

    # Reset all state (useful for testing)
    # @return [void]
    # @api private
    def reset!
      @processor&.stop
      @processor = nil
      @configuration = nil
    end
  end
end
