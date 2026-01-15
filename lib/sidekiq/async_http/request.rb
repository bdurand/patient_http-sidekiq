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
      @id = SecureRandom.uuid
      @method = method.is_a?(String) ? method.downcase.to_sym : method
      @url = url.is_a?(URI::Generic) ? url.to_s : url
      @headers = headers.is_a?(HttpHeaders) ? headers : HttpHeaders.new(headers)
      if Sidekiq::AsyncHttp.configuration.user_agent
        @headers["user-agent"] ||= Sidekiq::AsyncHttp.configuration.user_agent.to_s
      end
      @body = body
      @timeout = timeout
      @connect_timeout = connect_timeout
      @job = nil
      @completion_worker_class = nil
      @error_worker_class = nil
      @enqueued_at = nil
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
    # @return [String] the request ID
    def execute(completion_worker:, sidekiq_job: nil, error_worker: nil)
      # Get current job if not provided
      @job = sidekiq_job || (defined?(Sidekiq::AsyncHttp::Context) ? Sidekiq::AsyncHttp::Context.current_job : nil)

      # Validate sidekiq_job
      if @job.nil?
        raise ArgumentError, "sidekiq_job is required (provide hash or ensure Sidekiq::AsyncHttp::Context.current_job is set)"
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

      # Check if processor is running
      processor = Sidekiq::AsyncHttp.processor

      # If processor is running, use it (takes precedence over inline mode)
      if processor&.running?
        # Create RequestTask and enqueue to processor
        task = RequestTask.new(
          request: self,
          sidekiq_job: @job,
          completion_worker: completion_worker,
          error_worker: error_worker
        )
        processor.enqueue(task)

        # Return the request ID
        return @id
      end

      # If processor is not running but we're in inline mode, execute inline
      if defined?(Sidekiq::Testing) && Sidekiq::Testing.inline?
        return execute_inline(completion_worker, error_worker)
      end

      # Otherwise, raise an error
      raise Sidekiq::AsyncHttp::NotRunningError, "Cannot enqueue request: processor is not running"
    end

    private

    # Execute the HTTP request inline (synchronously) and invoke callbacks inline.
    # This is used when Sidekiq.testing mode is set to :inline.
    #
    # @param completion_worker [Class] Worker class for success callback
    # @param error_worker [Class, nil] Worker class for error callback
    # @return [String] the request ID
    def execute_inline(completion_worker, error_worker)
      require "net/http"
      require "uri"

      uri = URI.parse(@url)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        # Create HTTP client
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = @connect_timeout if @connect_timeout
        http.read_timeout = @timeout if @timeout

        # Create request
        request_class = case @method
        when :get then Net::HTTP::Get
        when :post then Net::HTTP::Post
        when :put then Net::HTTP::Put
        when :patch then Net::HTTP::Patch
        when :delete then Net::HTTP::Delete
        else
          raise ArgumentError, "Unsupported method: #{@method}"
        end

        request = request_class.new(uri.request_uri)

        # Set headers
        @headers.each do |key, value|
          request[key] = value
        end

        # Set body if present
        request.body = @body if @body

        # Execute request
        http_response = http.request(request)

        # Calculate duration
        end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        duration = end_time - start_time

        # Build response object
        response = Response.new(
          status: http_response.code.to_i,
          headers: http_response.to_hash.transform_values { |v| v.is_a?(Array) ? v.join(", ") : v },
          body: http_response.body,
          protocol: http_response.http_version,
          duration: duration,
          request_id: @id,
          url: @url,
          method: @method
        )

        # Invoke completion callback inline
        completion_worker.new.perform(response.to_h, *@job["args"])
      rescue => e
        # Calculate duration
        end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        duration = end_time - start_time

        if error_worker
          # Build error object and invoke error callback inline
          error = Error.from_exception(e, request_id: @id, duration: duration, url: @url, method: @method)
          error_worker.new.perform(error.to_h, *@job["args"])
        else
          # No error worker - re-enqueue the original job only if it's not already a continuation
          # This prevents infinite loops
          unless @job["async_http_continuation"]
            Sidekiq::Client.push(@job)
          end
        end
      end

      @id
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
  end
end
