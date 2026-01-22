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
    attr_reader :method

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

    # Initializes a new Request.
    #
    # @param method [Symbol, String] HTTP method (:get, :post, :put, :patch, :delete).
    # @param url [String, URI::Generic] The request URL.
    # @param headers [Hash, HttpHeaders] Request headers.
    # @param body [String, nil] Request body.
    # @param timeout [Float, nil] Overall timeout in seconds.
    # @param connect_timeout [Float, nil] Connect timeout in seconds.
    def initialize(method:, url:, headers: {}, body: nil, timeout: nil, connect_timeout: nil)
      @method = method.is_a?(String) ? method.downcase.to_sym : method
      @url = url.is_a?(URI::Generic) ? url.to_s : url
      @headers = headers.is_a?(HttpHeaders) ? headers : HttpHeaders.new(headers)
      if Sidekiq::AsyncHttp.configuration.user_agent
        @headers["user-agent"] ||= Sidekiq::AsyncHttp.configuration.user_agent.to_s
      end
      @body = body
      @timeout = timeout
      @connect_timeout = connect_timeout
      validate!
    end

    # Prepare the request for execution with callback workers.
    #
    # @param sidekiq_job [Hash, nil] Sidekiq job hash with "class" and "args" keys.
    #   If not provided, uses Sidekiq::AsyncHttp::Context.current_job.
    #   This requires the Sidekiq::AsyncHttp::Context::Middleware to be added
    #   to the Sidekiq server middleware chain. This is done by default if you require
    #   the "sidekiq/async_http/sidekiq" file.
    # @param completion_worker [Class] Worker class (must include Sidekiq::Job) to call on successful response
    # @param error_worker [Class, nil] Worker class (must include Sidekiq::Job) to call on error.
    #   If nil, errors will be logged and the original job will be retried.
    # @param synchronous [Boolean] If true, runs the request inline (for testing).
    # @return [String] the request ID
    def execute(completion_worker:, sidekiq_job: nil, error_worker: nil, synchronous: false)
      # Get current job if not provided
      sidekiq_job ||= (defined?(Sidekiq::AsyncHttp::Context) ? Sidekiq::AsyncHttp::Context.current_job : nil)

      # Validate sidekiq_job
      if sidekiq_job.nil?
        raise ArgumentError, "sidekiq_job is required (provide hash or ensure Sidekiq::AsyncHttp::Context.current_job is set)"
      end

      unless sidekiq_job.is_a?(Hash)
        raise ArgumentError, "sidekiq_job must be a Hash, got: #{sidekiq_job.class}"
      end

      unless sidekiq_job.key?("class")
        raise ArgumentError, "sidekiq_job must have 'class' key"
      end

      unless sidekiq_job["args"].is_a?(Array)
        raise ArgumentError, "sidekiq_job must have 'args' array"
      end

      # Validate completion_worker
      if completion_worker.nil?
        raise ArgumentError, "completion_worker is required"
      end

      unless completion_worker.is_a?(Class) && completion_worker.include?(Sidekiq::Job)
        raise ArgumentError, "completion_worker must be a class that includes Sidekiq::Job"
      end

      # Validate error_worker if provided
      if error_worker && !(error_worker.is_a?(Class) && error_worker.include?(Sidekiq::Job))
        raise ArgumentError, "error_worker must be a class that includes Sidekiq::Job"
      end

      task = RequestTask.new(
        request: self,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker
      )

      # Run the request inline if Sidekiq::Testing.inline! is enabled
      if synchronous || async_disabled?
        InlineRequest.new(task).execute
        return task.id
      end

      # Check if processor is running
      processor = Sidekiq::AsyncHttp.processor
      unless processor&.running?
        raise Sidekiq::AsyncHttp::NotRunningError, "Cannot enqueue request: processor is not running"
      end

      processor.enqueue(task)

      task.id
    end

    private

    # Validate the request has required HTTP parameters.
    # @raise [ArgumentError] if method or url is invalid
    # @return [self] for chaining
    def validate!
      unless VALID_METHODS.include?(@method)
        raise ArgumentError, "method must be one of #{VALID_METHODS.inspect}, got: #{@method.inspect}"
      end

      if @url.nil? || (@url.is_a?(String) && @url.empty?)
        raise ArgumentError, "url is required"
      end

      unless @url.is_a?(String) || @url.is_a?(URI::Generic)
        raise ArgumentError, "url must be a String or URI, got: #{@url.class}"
      end

      if [:get, :delete].include?(@method) && !@body.nil?
        raise ArgumentError, "body is not allowed for #{@method.upcase} requests"
      end

      self
    end

    def async_disabled?
      defined?(Sidekiq::Testing) && Sidekiq::Testing.inline?
    end
  end
end
