# frozen_string_literal: true

require "securerandom"

module Sidekiq::AsyncHttp
  # Represents an async HTTP request that will be processed by the async processor.
  #
  # Created by Client#async_request and its convenience methods (async_get, async_post, etc.).
  # Must call perform() with callback workers to enqueue the request for execution.
  #
  # The request validates that it has a method and URL. The perform call validates
  # the Sidekiq job hash and success worker are provided.
  class Request
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

    # @return [Float, nil] Overall timeout in seconds
    attr_reader :timeout

    # @return [Float, nil] Connect timeout in seconds
    attr_reader :connect_timeout

    # @return [Integer, nil] Maximum number of redirects to follow (nil uses config default, 0 disables)
    attr_reader :max_redirects

    # Initializes a new Request.
    #
    # @param http_method [Symbol, String] HTTP method (:get, :post, :put, :patch, :delete).
    # @param url [String, URI::Generic] The request URL.
    # @param headers [Hash, HttpHeaders] Request headers.
    # @param body [String, nil] Request body.
    # @param timeout [Float, nil] Overall timeout in seconds.
    # @param connect_timeout [Float, nil] Connect timeout in seconds.
    # @param max_redirects [Integer, nil] Maximum redirects to follow (nil uses config, 0 disables).
    def initialize(
      http_method,
      url,
      headers: {},
      body: nil,
      timeout: nil,
      connect_timeout: nil,
      max_redirects: nil
    )
      @http_method = http_method.is_a?(String) ? http_method.downcase.to_sym : http_method
      @url = url.is_a?(URI::Generic) ? url.to_s : url
      @headers = headers.is_a?(HttpHeaders) ? headers : HttpHeaders.new(headers)
      if Sidekiq::AsyncHttp.configuration.user_agent
        @headers["user-agent"] ||= Sidekiq::AsyncHttp.configuration.user_agent.to_s
      end
      @body = body
      @timeout = timeout
      @connect_timeout = connect_timeout
      @max_redirects = max_redirects
      validate!
    end

    # Execute the request. The request will be processed asynchronously. If the
    # request gets a response from the server, the completion_worker will be called.
    # If an error occurs (network error, timeout, or non-2xx response if raise_error_responses
    # is true), the error_worker will be called.
    #
    # @param sidekiq_job [Hash, nil] Sidekiq job hash with "class" and "args" keys.
    #   If not provided, uses Sidekiq::AsyncHttp::Context.current_job.
    #   This requires the Sidekiq::AsyncHttp::Context::Middleware to be added
    #   to the Sidekiq server middleware chain. This is done by default if you require
    #   the "sidekiq/async_http/sidekiq" file.
    # @param completion_worker [Class] Worker class (must include Sidekiq::Job) to call on successful response
    # @param error_worker [Class] Worker class (must include Sidekiq::Job) to call on error.
    # @param synchronous [Boolean] If true, runs the request inline (for testing).
    # @param callback_args [#to_h, nil] Arguments to pass to callback workers via the
    #   Response/Error object. Must respond to to_h and contain only JSON-native types
    #   (nil, true, false, String, Integer, Float, Array, Hash). All hash keys (including
    #   nested hashes and hashes in arrays) will be deeply converted to strings for serialization.
    #   Access via response.callback_args or error.callback_args using symbol or string keys.
    # @param raise_error_responses [Boolean] If true, raises an HttpError for non-2xx responses
    #   and calls the error_worker instead of completion_worker. Defaults to false.
    #
    # @return [String] the request ID
    def execute(
      completion_worker:,
      error_worker:,
      sidekiq_job: nil,
      synchronous: false,
      callback_args: nil,
      raise_error_responses: false
    )
      sidekiq_job = validate_sidekiq_job(sidekiq_job)
      validate_callback_workers!(completion_worker, error_worker)
      validated_callback_args = validate_callback_args(callback_args)

      task = RequestTask.new(
        request: self,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker,
        callback_args: validated_callback_args,
        raise_error_responses: raise_error_responses
      )

      # Run the request inline if Sidekiq::Testing.inline! is enabled
      if synchronous || async_disabled?
        InlineRequest.new(task).execute
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

    private

    def validate_sidekiq_job(sidekiq_job)
      sidekiq_job ||= Sidekiq::AsyncHttp::Context.current_job

      if sidekiq_job.nil?
        raise ArgumentError.new("sidekiq_job is required (provide hash or ensure Sidekiq::AsyncHttp::Context.current_job is set)")
      end

      raise ArgumentError.new("sidekiq_job must be a Hash, got: #{sidekiq_job.class}") unless sidekiq_job.is_a?(Hash)

      raise ArgumentError.new("sidekiq_job must have 'class' key") unless sidekiq_job.key?("class")

      raise ArgumentError.new("sidekiq_job must have 'args' array") unless sidekiq_job["args"].is_a?(Array)

      sidekiq_job
    end

    def validate_callback_workers!(completion_worker, error_worker)
      unless completion_worker.is_a?(Class) && completion_worker.include?(Sidekiq::Job)
        raise ArgumentError.new("completion_worker must be a class that includes Sidekiq::Job")
      end

      unless error_worker.is_a?(Class) && error_worker.include?(Sidekiq::Job)
        raise ArgumentError.new("error_worker must be a class that includes Sidekiq::Job")
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

      self
    end

    def async_disabled?
      defined?(Sidekiq::Testing) && Sidekiq::Testing.inline?
    end
  end
end
