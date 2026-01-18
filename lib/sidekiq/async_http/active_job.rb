# frozen_string_literal: true

module Sidekiq::AsyncHttp
  # Mixin module for ActiveJob classes that provides async HTTP functionality.
  #
  # Including this module in an ActiveJob class adds methods for making asynchronous
  # HTTP requests that are processed outside the job thread.
  #
  # @example
  #   class MyJob < ApplicationJob
  #     include Sidekiq::AsyncHttp::ActiveJob
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
  module ActiveJob
    class << self
      # Hook called when the module is included in a class.
      #
      # Ensures the base class inherits from ::ActiveJob::Base and extends it with ClassMethods.
      #
      # @param base [Class] the class including this module
      def included(base)
        unless base.ancestors.include?(::ActiveJob::Base)
          raise TypeError, "#{base} must inherit from ActiveJob::Base to include Sidekiq::AsyncHttp::ActiveJob"
        end
        base.extend(ClassMethods)
      end
    end

    # Class methods added to the including job class.
    module ClassMethods
      # @return [Class] the success callback job class
      attr_reader :completion_callback_job

      # @return [Class] the error callback job class
      attr_reader :error_callback_job

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
      # @param base_class [Class, nil] optional base class for the callback job (defaults to parent class)
      # @yield [response, *args] block to execute on successful response
      # @yieldparam response [Response] the HTTP response
      # @yieldparam args [Array] additional arguments passed to the job
      def on_completion(base_class = nil, &block)
        on_completion_block = block
        base_class ||= superclass

        job_class = Class.new(base_class) do
          def perform(response_data, *args)
            response = Sidekiq::AsyncHttp::Response.load(response_data)
            self.class.on_completion_block.call(response, *args)
          end

          class << self
            attr_accessor :on_completion_block
          end
        end

        job_class.on_completion_block = on_completion_block

        const_set(:CompletionCallback, job_class)
        self.completion_callback_job = const_get(:CompletionCallback)
      end

      # Sets the success callback job class.
      #
      # @param job_class [Class] the job class that inherits from ActiveJob::Base
      # @raise [ArgumentError] if job_class is not a valid ActiveJob class
      def completion_callback_job=(job_class)
        unless job_class.is_a?(Class) && job_class.ancestors.include?(::ActiveJob::Base)
          raise ArgumentError, "completion_callback_job must be an ActiveJob::Base class"
        end

        @completion_callback_job = job_class
      end

      # Defines an error callback for HTTP requests.
      #
      # @param base_class [Class, nil] optional base class for the callback job (defaults to parent class)
      # @yield [error, *args] block to execute on error
      # @yieldparam error [Error] the HTTP error
      # @yieldparam args [Array] additional arguments passed to the job
      def on_error(base_class = nil, &block)
        error_callback_block = block
        base_class ||= superclass

        job_class = Class.new(base_class) do
          def perform(error_data, *args)
            error = Sidekiq::AsyncHttp::Error.load(error_data)
            self.class.error_callback_block.call(error, *args)
          end

          class << self
            attr_accessor :error_callback_block
          end
        end

        job_class.error_callback_block = error_callback_block

        const_set(:ErrorCallback, job_class)
        self.error_callback_job = const_get(:ErrorCallback)
      end

      # Sets the error callback job class.
      #
      # @param job_class [Class] the job class that inherits from ActiveJob::Base
      # @raise [ArgumentError] if job_class is not a valid ActiveJob class
      def error_callback_job=(job_class)
        unless job_class.is_a?(Class) && job_class.ancestors.include?(::ActiveJob::Base)
          raise ArgumentError, "error_callback_job must be an ActiveJob::Base class"
        end

        @error_callback_job = job_class
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
      completion_job ||= options.delete(:completion_job)
      error_job ||= options.delete(:error_job)

      completion_job ||= self.class.completion_callback_job
      error_job ||= self.class.error_callback_job

      request = client.async_request(method, url, **options)
      request.execute(completion_worker: completion_job, error_worker: error_job)
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
