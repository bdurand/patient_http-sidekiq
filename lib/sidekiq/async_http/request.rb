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

    attr_reader :id, :method, :url, :headers, :body, :timeout, :read_timeout, :connect_timeout, :write_timeout

    def initialize(method:, url:, headers: {}, body: nil, timeout: nil, read_timeout: nil, connect_timeout: nil, write_timeout: nil)
      @id = SecureRandom.uuid
      @method = method.is_a?(String) ? method.downcase.to_sym : method
      @url = url
      @headers = headers
      @body = body
      @timeout = timeout
      @read_timeout = read_timeout
      @connect_timeout = connect_timeout
      @write_timeout = write_timeout
      @job = nil
      @success_worker_class = nil
      @error_worker_class = nil
      @enqueued_at = nil
      validate!
    end

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

    # Prepare the request for execution with callback workers.
    #
    # @param sidekiq_job [Hash, nil] Sidekiq job hash with "class" and "args" keys.
    #   If not provided, uses Sidekiq::Context.current (Sidekiq 8+).
    # @param success_worker [Class] Worker class (must include Sidekiq::Job) to call on successful response
    # @param error_worker [Class, nil] Worker class (must include Sidekiq::Job) to call on error.
    #   If nil, errors will be logged and the original job will be retried.
    # @return [String] the request ID
    def perform(success_worker:, sidekiq_job: nil, error_worker: nil)
      # Get current job if not provided
      @job = sidekiq_job || (defined?(Sidekiq::Context) ? Sidekiq::Context.current : nil)

      # Validate sidekiq_job
      if @job.nil?
        raise ArgumentError, "sidekiq_job is required (provide hash or ensure Sidekiq::Context.current is set)"
      end

      unless @job.is_a?(Hash)
        raise ArgumentError, "sidekiq_job must be a Hash, got: #{@job.class}"
      end

      unless @job.key?("class")
        raise ArgumentError, "sidekiq_job must have 'class' key"
      end

      unless @job["args"].is_a?(Array)
        raise ArgumentError, "sidekiq_job must have 'args' array"
      end

      # Validate success_worker
      if success_worker.nil?
        raise ArgumentError, "success_worker is required"
      end

      unless success_worker.is_a?(Class) && success_worker.include?(Sidekiq::Job)
        raise ArgumentError, "success_worker must be a class that includes Sidekiq::Job"
      end

      # Validate error_worker if provided
      if error_worker && !(error_worker.is_a?(Class) && error_worker.include?(Sidekiq::Job))
        raise ArgumentError, "error_worker must be a class that includes Sidekiq::Job"
      end

      # Check if processor is running
      processor = Sidekiq::AsyncHttp.processor
      unless processor.running?
        raise Sidekiq::AsyncHttp::NotRunningError, "Cannot enqueue request: processor is not running"
      end

      # Create RequestTask and enqueue to processor
      task = RequestTask.new(
        request: self,
        sidekiq_job: @job,
        success_worker: success_worker,
        error_worker: error_worker
      )
      processor.enqueue(task)

      # Return the request ID
      @id
    end
  end
end
