# frozen_string_literal: true

module Sidekiq::AsyncHttp
  # Mixin module for Sidekiq jobs that provides async HTTP functionality.
  #
  # Including this module in a Sidekiq job class adds methods for making asynchronous
  # HTTP requests that are processed outside the worker thread.
  #
  # @example
  #   class MyJob
  #     include Sidekiq::AsyncHttp::Job
  #
  #     on_completion do |response, *args|
  #       # Handle successful response
  #     end
  #
  #     on_error do |error, *args|
  #       # Handle error
  #     end
  #
  #     def perform(*args)
  #       async_get("https://api.example.com/data")
  #     end
  #   end
  module Job
    class << self
      # Hook called when the module is included in a class.
      #
      # Ensures the base class includes Sidekiq::Job and extends it with ClassMethods.
      #
      # @param base [Class] the class including this module
      def included(base)
        base.include(Sidekiq::Job) unless base.include?(Sidekiq::Job)
        base.extend(ClassMethods)
      end
    end

    # Class methods added to the including job class.
    module ClassMethods
      # @return [Class] the success callback worker class
      attr_reader :completion_callback_worker

      # @return [Class] the error callback worker class
      attr_reader :error_callback_worker

      # Configures the HTTP client for this job class.
      #
      # @param options [Hash] client configuration options
      # @option options [String] :base_url Base URL for relative requests
      # @option options [Hash] :headers Default headers
      # @option options [Float] :timeout Default timeout
      def client(**options)
        @client = Sidekiq::AsyncHttp::Client.new(**options)
      end

      # Defines a success callback for HTTP requests.
      #
      # @param options [Hash] Sidekiq options for the callback worker
      # @yield [response, *args] block to execute on successful response
      # @yieldparam response [Response] the HTTP response
      # @yieldparam args [Array] additional arguments passed to the job
      def on_completion(options = {}, &block)
        on_completion_block = block

        worker_class = Class.new do
          include Sidekiq::Job

          sidekiq_options(options) unless options.empty?

          define_method(:perform) do |response_data, *args|
            response = Sidekiq::AsyncHttp::Response.from_h(response_data)
            on_completion_block.call(response, *args)
          end
        end

        const_set(:CompletionCallback, worker_class)
        self.completion_callback_worker = const_get(:CompletionCallback)
      end

      # Sets the success callback worker class.
      #
      # @param worker_class [Class] the worker class that includes Sidekiq::Job
      # @raise [ArgumentError] if worker_class is not a valid Sidekiq job class
      def completion_callback_worker=(worker_class)
        unless worker_class.is_a?(Class) && worker_class.included_modules.include?(Sidekiq::Job)
          raise ArgumentError, "completion_callback_worker must be a Sidekiq::Job class"
        end

        @completion_callback_worker = worker_class
      end

      # Defines an error callback for HTTP requests.
      #
      # @param options [Hash] Sidekiq options for the callback worker
      # @yield [error, *args] block to execute on error
      # @yieldparam error [Error] the HTTP error
      # @yieldparam args [Array] additional arguments passed to the job
      def on_error(options = {}, &block)
        error_callback_block = block

        worker_class = Class.new do
          include Sidekiq::Job

          sidekiq_options(options) unless options.empty?

          define_method(:perform) do |error_data, *args|
            error = Sidekiq::AsyncHttp::Error.from_h(error_data)
            error_callback_block.call(error, *args)
          end
        end

        const_set(:ErrorCallback, worker_class)
        self.error_callback_worker = const_get(:ErrorCallback)
      end

      # Sets the error callback worker class.
      #
      # @param worker_class [Class] the worker class that includes Sidekiq::Job
      # @raise [ArgumentError] if worker_class is not a valid Sidekiq job class
      def error_callback_worker=(worker_class)
        unless worker_class.is_a?(Class) && worker_class.included_modules.include?(Sidekiq::Job)
          raise ArgumentError, "error_callback_worker must be a Sidekiq::Job class"
        end

        @error_callback_worker = worker_class
      end
    end

    # Returns the HTTP client for this job instance.
    #
    # @return [Client] the configured client or a default client
    def client
      self.class.instance_variable_get(:@client) || Sidekiq::AsyncHttp::Client.new
    end

    # Makes an asynchronous HTTP request.
    #
    # @param method [Symbol] HTTP method (:get, :post, :put, :patch, :delete)
    # @param url [String] the request URL
    # @param options [Hash] additional request options
    # @return [String] request ID
    def async_request(method, url, **options)
      options = options.dup
      completion_worker ||= options.delete(:completion_worker)
      error_worker ||= options.delete(:error_worker)

      completion_worker ||= self.class.completion_callback_worker
      error_worker ||= self.class.error_callback_worker

      request = client.async_request(method, url, **options)
      request.execute(completion_worker: completion_worker, error_worker: error_worker)
    end

    # Convenience method for GET requests.
    #
    # @param url [String] the request URL
    # @param options [Hash] additional request options
    # @return [String] request ID
    def async_get(url, **options)
      async_request(:get, url, **options)
    end

    # Convenience method for POST requests.
    #
    # @param url [String] the request URL
    # @param options [Hash] additional request options
    # @return [String] request ID
    def async_post(url, **options)
      async_request(:post, url, **options)
    end

    # Convenience method for PUT requests.
    #
    # @param url [String] the request URL
    # @param options [Hash] additional request options
    # @return [String] request ID
    def async_put(url, **options)
      async_request(:put, url, **options)
    end

    # Convenience method for PATCH requests.
    #
    # @param url [String] the request URL
    # @param options [Hash] additional request options
    # @return [String] request ID
    def async_patch(url, **options)
      async_request(:patch, url, **options)
    end

    # Convenience method for DELETE requests.
    #
    # @param url [String] the request URL
    # @param options [Hash] additional request options
    # @return [String] request ID
    def async_delete(url, **options)
      async_request(:delete, url, **options)
    end
  end
end
