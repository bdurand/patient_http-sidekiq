# frozen_string_literal: true

require "securerandom"

module Sidekiq::AsyncHttp
  # Represents an async HTTP request that will be processed by the async processor.
  #
  # Created by Client#async_request and its convenience methods (async_get, async_post, etc.).
  #
  # There are two ways to execute a request:
  #
  # - +async_execute+ - Enqueues a Sidekiq job to make the request. Can be called from
  #   anywhere (controllers, scripts, other jobs, etc.). This is the recommended method
  #   for most use cases.
  #
  # - +execute+ - Directly enqueues the request to the async processor. Must be called
  #   from within a Sidekiq job context. Used internally by RequestWorker.
  #
  # @example Using async_execute (recommended)
  #   client = Sidekiq::AsyncHttp::Client.new(base_url: "https://api.example.com")
  #   request = client.async_get("/users/123")
  #   request.async_execute(callback: MyCallback, callback_args: {user_id: 123})
  #
  # @example The callback service
  #   class MyCallback
  #     def on_complete(response)
  #       User.find(response.callback_args[:user_id]).update!(data: response.json)
  #     end
  #
  #     def on_error(error)
  #       Rails.logger.error("Request failed: #{error.message}")
  #     end
  #   end
  class Request
    include ExternalStorage

    # Valid HTTP methods
    VALID_METHODS = %i[get post put patch delete].freeze

    # @return [Symbol] HTTP method (:get, :post, :put, :patch, :delete)
    attr_reader :http_method

    # @return [String] The request URL
    attr_reader :url

    # @return [HttpHeaders] Request headers
    attr_reader :headers

    # @return [String, nil] Request body
    attr_reader :body

    # @return [Numeric, nil] Overall timeout in seconds
    attr_reader :timeout

    # @return [Integer, nil] Maximum number of redirects to follow (nil uses config default, 0 disables)
    attr_reader :max_redirects

    class << self
      # Reconstruct a Request from a hash
      #
      # @param hash [Hash] hash representation
      # @return [Request] reconstructed request
      def load(hash)
        new(
          hash["http_method"].to_sym,
          hash["url"],
          headers: hash["headers"],
          body: hash["body"],
          timeout: hash["timeout"],
          max_redirects: hash["max_redirects"]
        )
      end
    end

    # Initializes a new Request.
    #
    # @param http_method [Symbol, String] HTTP method (:get, :post, :put, :patch, :delete).
    # @param url [String, URI::Generic] The request URL.
    # @param headers [Hash, HttpHeaders] Request headers.
    # @param body [String, nil] Request body.
    # @param timeout [Numeric, nil] Overall timeout in seconds.
    # @param max_redirects [Integer, nil] Maximum redirects to follow (nil uses config, 0 disables).
    def initialize(
      http_method,
      url,
      headers: {},
      body: nil,
      timeout: nil,
      max_redirects: nil
    )
      @http_method = http_method.is_a?(String) ? http_method.downcase.to_sym : http_method
      @url = url.is_a?(URI::Generic) ? url.to_s : url
      @headers = headers.is_a?(HttpHeaders) ? headers : HttpHeaders.new(headers)
      @body = (body == "") ? nil : body
      @timeout = timeout
      @max_redirects = max_redirects
      validate!
    end

    # Execute the request directly on the async processor.
    #
    # This method enqueues the request directly to the async processor. It must be
    # called from within a Sidekiq job context (the sidekiq_job parameter is required).
    # Used internally by RequestWorker.
    #
    # For most use cases, prefer {#async_execute} which can be called from anywhere.
    #
    # When the request completes, the callback's +on_complete+ method is called with
    # a Response object. If an error occurs (network error, timeout, or non-2xx response
    # if raise_error_responses is true), the +on_error+ method is called with an Error object.
    #
    # @param callback [Class, String] Callback service class with +on_complete+ and +on_error+
    #   instance methods, or its fully qualified class name.
    # @param sidekiq_job [Hash, nil] Sidekiq job hash with "class" and "args" keys.
    #   If not provided, uses Sidekiq::AsyncHttp::Context.current_job.
    #   This requires the Sidekiq::AsyncHttp::Context::Middleware to be added
    #   to the Sidekiq server middleware chain.
    # @param synchronous [Boolean] If true, runs the request inline (for testing).
    # @param callback_args [#to_h, nil] Arguments to pass to callback via the
    #   Response/Error object. Must respond to +to_h+ and contain only JSON-native types
    #   (nil, true, false, String, Integer, Float, Array, Hash). All hash keys will be
    #   converted to strings for serialization. Access via +response.callback_args+ or
    #   +error.callback_args+ using symbol or string keys.
    # @param raise_error_responses [Boolean] If true, treats non-2xx responses as errors
    #   and calls +on_error+ instead of +on_complete+. Defaults to false.
    # @param request_id [String, nil] Unique request ID for tracking. If nil, a new UUID
    #   will be generated.
    # @return [String] the request ID
    # @api private
    def execute(
      callback:,
      sidekiq_job: nil,
      synchronous: false,
      callback_args: nil,
      raise_error_responses: false,
      request_id: nil
    )
      sidekiq_job = validate_sidekiq_job(sidekiq_job)
      validate_callback!(callback)
      validated_callback_args = validate_callback_args(callback_args)

      task = RequestTask.new(
        request: self,
        sidekiq_job: sidekiq_job,
        callback: callback,
        callback_args: validated_callback_args,
        raise_error_responses: raise_error_responses,
        id: request_id
      )

      # Run the request inline if Sidekiq::Testing.inline! is enabled
      if synchronous || async_disabled?
        SynchronousExecutor.new(task).call
        return task.id
      end

      # Check if processor is running
      processor = Sidekiq::AsyncHttp.processor
      unless processor&.running?
        raise Sidekiq::AsyncHttp::NotRunningError.new("Cannot enqueue request: processor is not running")
      end

      processor.enqueue(task)

      task.id
    end

    # Enqueue the request for asynchronous execution via a Sidekiq job.
    #
    # This method enqueues a RequestWorker job that will execute the HTTP request
    # asynchronously. Can be called from anywhere (controllers, scripts, other jobs, etc.).
    #
    # When the request completes, the callback's +on_complete+ method is called with
    # a Response object. If an error occurs, the +on_error+ method is called with
    # an Error object.
    #
    # @param callback [Class, String] Callback service class with +on_complete+ and +on_error+
    #   instance methods, or its fully qualified class name.
    # @param synchronous [Boolean] If true, runs the request inline (for testing).
    # @param callback_args [#to_h, nil] Arguments to pass to callback via the
    #   Response/Error object. Must respond to +to_h+ and contain only JSON-native types
    #   (nil, true, false, String, Integer, Float, Array, Hash). All hash keys will be
    #   converted to strings for serialization. Access via +response.callback_args+ or
    #   +error.callback_args+ using symbol or string keys.
    # @param raise_error_responses [Boolean] If true, treats non-2xx responses as errors
    #   and calls +on_error+ instead of +on_complete+. Defaults to false.
    # @return [String] the request ID
    def async_execute(
      callback:,
      synchronous: false,
      callback_args: nil,
      raise_error_responses: false
    )
      validate_callback!(callback)
      callback_name = callback.is_a?(Class) ? callback.name : callback.to_s
      callback_args = validate_callback_args(callback_args)
      request_id = SecureRandom.uuid

      RequestWorker.perform_async(as_json, callback_name, raise_error_responses, callback_args, request_id)

      request_id
    end

    private

    def original_as_json
      {
        "http_method" => @http_method.to_s,
        "url" => @url.to_s,
        "headers" => @headers.to_h,
        "body" => @body,
        "timeout" => @timeout,
        "max_redirects" => @max_redirects
      }
    end

    def validate_sidekiq_job(sidekiq_job)
      sidekiq_job ||= Sidekiq::AsyncHttp::Context.current_job

      raise ArgumentError.new("sidekiq_job is required") if sidekiq_job.nil?

      raise ArgumentError.new("sidekiq_job must be a Hash, got: #{sidekiq_job.class}") unless sidekiq_job.is_a?(Hash)

      raise ArgumentError.new("sidekiq_job must have 'class' key") unless sidekiq_job.key?("class")

      raise ArgumentError.new("sidekiq_job must have 'args' array") unless sidekiq_job["args"].is_a?(Array)

      sidekiq_job
    end

    def validate_callback!(callback)
      callback_class = callback.is_a?(Class) ? callback : ClassHelper.resolve_class_name(callback)

      validate_callback_method!(callback_class, :on_complete)
      validate_callback_method!(callback_class, :on_error)
    end

    def validate_callback_method!(callback_class, method_name)
      unless callback_class.method_defined?(method_name)
        raise ArgumentError.new("callback class must define ##{method_name} instance method")
      end

      method = callback_class.instance_method(method_name)
      # arity of 1 = exactly 1 required arg, -1 = any args (*args), -2 = 1 required + splat
      unless method.arity == 1 || method.arity == -1 || method.arity == -2
        raise ArgumentError.new("callback class ##{method_name} must accept exactly 1 positional argument")
      end
    end

    # Validate callback_args and convert to a hash with string keys.
    #
    # @param callback_args [#to_h, nil] the callback arguments
    # @return [Hash, nil] validated hash with string keys, or nil
    # @raise [ArgumentError] if callback_args is invalid
    def validate_callback_args(callback_args)
      return nil if callback_args.nil?

      unless callback_args.respond_to?(:to_h)
        raise ArgumentError.new("callback_args must respond to to_h, got #{callback_args.class.name}")
      end

      hash = callback_args.to_h
      hash.each do |key, value|
        CallbackArgs.validate_value!(value, key.to_s)
      end
      hash.transform_keys(&:to_s)
    end

    # Validate the request has required HTTP parameters.
    # @raise [ArgumentError] if method or url is invalid
    # @return [self] for chaining
    def validate!
      unless VALID_METHODS.include?(@http_method)
        raise ArgumentError.new("method must be one of #{VALID_METHODS.inspect}, got: #{@http_method.inspect}")
      end

      raise ArgumentError.new("url is required") if @url.nil? || (@url.is_a?(String) && @url.empty?)

      unless @url.is_a?(String) || @url.is_a?(URI::Generic)
        raise ArgumentError.new("url must be a String or URI, got: #{@url.class}")
      end

      if %i[get delete].include?(@http_method) && !@body.nil?
        raise ArgumentError.new("body is not allowed for #{@http_method.upcase} requests")
      end

      if @body && !@body.is_a?(String)
        raise ArgumentError.new("body must be a String, got: #{@body.class}")
      end

      self
    end

    def async_disabled?
      defined?(Sidekiq::Testing) && Sidekiq::Testing.inline?
    end
  end
end
