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
  #     on_completion do |response|
  #       user_id = response.callback_args[:user_id]
  #       # Handle successful response
  #     end
  #
  #     on_error do |error|
  #       user_id = error.callback_args[:user_id]
  #       # Handle error
  #     end
  #
  #     def perform(user_id)
  #       async_get("https://api.example.com/data", callback_args: {user_id: user_id})
  #     end
  #   end
  #
  # This can also be included in ActiveJob classes if the queue adapter
  # is using Sidekiq.
  module Job
    class << self
      # Hook called when the module is included in a class.
      #
      # @param base [Class] the class including this module
      def included(base)
        if !(defined?(ActiveJob::Base) && base < ActiveJob::Base) && !base.include?(Sidekiq::Job)
          base.include(Sidekiq::Job)
        end

        base.extend(ClassMethods)
        base.async_http_client
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
      def async_http_client(**options)
        @async_http_client = Sidekiq::AsyncHttp::Client.new(**options)
      end

      # Defines a success callback for HTTP requests.
      #
      # The callback receives a single Response argument. Access any callback
      # arguments via response.callback_args.
      #
      # @param options [Hash] Sidekiq options for the callback worker
      # @yield [response] block to execute on successful response
      # @yieldparam response [Response] the HTTP response (includes callback_args)
      def on_completion(options = {}, &block)
        on_completion_block = block

        worker_class = Class.new do
          include Sidekiq::Job

          sidekiq_options(options) unless options.empty?

          define_method(:perform) do |response|
            on_completion_block.call(response)
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
          raise ArgumentError.new("completion_callback_worker must be a Sidekiq::Job class")
        end

        @completion_callback_worker = worker_class
      end

      # Defines an error callback for HTTP requests.
      #
      # The callback receives a single Error argument. Access any callback
      # arguments via error.callback_args.
      #
      # @param options [Hash] Sidekiq options for the callback worker
      # @yield [error] block to execute on error
      # @yieldparam error [Error] the HTTP error (includes callback_args)
      def on_error(options = {}, &block)
        error_callback_block = block

        worker_class = Class.new do
          include Sidekiq::Job

          sidekiq_options(options) unless options.empty?

          define_method(:perform) do |error|
            error_callback_block.call(error)
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
          raise ArgumentError.new("error_callback_worker must be a Sidekiq::Job class")
        end

        @error_callback_worker = worker_class
      end

      # Check if the class is an ActiveJob but not using Sidekiq as the queue adapter.
      #
      # @return [Boolean] true if Sidekiq is the queue adapter
      # @api private
      def asynchronous_http_requests_supported?
        if defined?(ActiveJob::Base) && self <= ActiveJob::Base
          queue_adapter_name == "sidekiq"
        else
          true
        end
      end
    end

    # Makes an asynchronous HTTP request.
    #
    # @param method [Symbol] HTTP method (:get, :post, :put, :patch, :delete)
    # @param url [String] the request URL
    # @param options [Hash] additional request options
    # @option options [Class] :completion_worker Worker class to call on successful response
    # @option options [Class] :error_worker Worker class to call on error
    # @option options [#to_h] :callback_args Arguments to include in the Response/Error object.
    #   Must respond to to_h and contain only JSON-native types. Access via response.callback_args.
    #
    # @return [String] request ID
    def async_request(method, url, **options)
      options = options.dup
      completion_worker = options.delete(:completion_worker)
      error_worker = options.delete(:error_worker)
      callback_args = options.delete(:callback_args)

      completion_worker ||= self.class.completion_callback_worker
      error_worker ||= self.class.error_callback_worker

      request = async_http_client.async_request(method, url, **options)
      request.execute(
        completion_worker: completion_worker,
        error_worker: error_worker,
        callback_args: callback_args
      )
    end

    # Convenience method for GET requests.
    #
    # @param url [String] the request URL
    # @param options [Hash] additional request options (see {#async_request})
    #
    # @return [String] request ID
    def async_get(url, **options)
      async_request(:get, url, **options)
    end

    # Convenience method for POST requests.
    #
    # @param url [String] the request URL
    # @param options [Hash] additional request options (see {#async_request})
    #
    # @return [String] request ID
    def async_post(url, **options)
      async_request(:post, url, **options)
    end

    # Convenience method for PUT requests.
    #
    # @param url [String] the request URL
    # @param options [Hash] additional request options (see {#async_request})
    #
    # @return [String] request ID
    def async_put(url, **options)
      async_request(:put, url, **options)
    end

    # Convenience method for PATCH requests.
    #
    # @param url [String] the request URL
    # @param options [Hash] additional request options (see {#async_request})
    #
    # @return [String] request ID
    def async_patch(url, **options)
      async_request(:patch, url, **options)
    end

    # Convenience method for DELETE requests.
    #
    # @param url [String] the request URL
    # @param options [Hash] additional request options (see {#async_request})
    #
    # @return [String] request ID
    def async_delete(url, **options)
      async_request(:delete, url, **options)
    end

    # Returns the HTTP client for this job instance.
    #
    # @return [Client] the configured client or a default client
    # @api private
    def async_http_client
      unless self.class.asynchronous_http_requests_supported?
        raise "Asynchronous HTTP requests are not supported with the #{self.class.queue_adapter_name} ActiveJob queue adapter"
      end

      self.class.instance_variable_get(:@async_http_client) || Sidekiq::AsyncHttp::Client.new
    end
  end
end
