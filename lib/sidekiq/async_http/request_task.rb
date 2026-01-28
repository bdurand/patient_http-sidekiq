# frozen_string_literal: true

module Sidekiq::AsyncHttp
  # A wrapper around {Request} that includes callback and job context for the Processor.
  # This class allows HTTP requests to be enqueued and processed asynchronously,
  # tracking their lifecycle and providing methods to handle success and error callbacks.
  class RequestTask
    include TimeHelper

    # @return [String] Unique UUID for tracking the task
    attr_reader :id

    # @return [Request] The HTTP request details
    attr_reader :request

    # @return [Hash] The Sidekiq job hash containing class, jid, args, etc.
    attr_reader :sidekiq_job

    # @return [String] Class name for the success callback worker
    attr_reader :completion_worker

    # @return [String, nil] Class name for the error callback worker, optional
    attr_reader :error_worker

    # @return [Hash] Callback arguments to include in Response/Error objects (never nil, defaults to empty hash)
    attr_reader :callback_args

    # @return [Response, nil] The HTTP response, set on success
    attr_reader :response, :error

    # Initializes a new RequestTask.
    #
    # @param request [Request] The HTTP request to wrap.
    # @param sidekiq_job [Hash] The Sidekiq job hash.
    # @param completion_worker [String] Class name for success callback.
    # @param error_worker [String, nil] Class name for error callback, optional.
    # @param callback_args [Hash] Callback arguments (with string keys) to include
    #   in Response/Error objects. These will be accessible via response.callback_args
    #   or error.callback_args.
    def initialize(request:, sidekiq_job:, completion_worker:, error_worker:, callback_args: {})
      @id = SecureRandom.uuid
      @request = request
      @sidekiq_job = sidekiq_job
      @completion_worker = completion_worker
      @error_worker = error_worker
      @callback_args = callback_args || {}
      @enqueued_at = nil
      @started_at = nil
      @completed_at = nil
      @response = nil
      @error = nil
    end

    # Mark task as enqueued
    # @return [void]
    def enqueued!
      @enqueued_at = monotonic_time
    end

    # Mark task as started
    # @return [void]
    def started!
      @started_at = monotonic_time
    end

    # Mark task as completed
    # @return [void]
    def completed!
      @completed_at = monotonic_time
    end

    # Returns the wall clock time when the task was enqueued.
    #
    # @return [Time, nil] The enqueued time or nil if not enqueued.
    def enqueued_at
      wall_clock_time(@enqueued_at) if @enqueued_at
    end

    # Returns the wall clock time when the task was started.
    #
    # @return [Time, nil] The started time or nil if not started.
    def started_at
      wall_clock_time(@started_at) if @started_at
    end

    # Returns the wall clock time when the task was completed.
    #
    # @return [Time, nil] The completed time or nil if not completed.
    def completed_at
      wall_clock_time(@completed_at) if @completed_at
    end

    # Enqueued duration in seconds.
    # @return [Float, nil] duration or nil if not enqueued yet.
    def enqueued_duration
      return nil unless @enqueued_at

      (@started_at || monotonic_time) - @enqueued_at
    end

    # Execution duration in seconds.
    # @return [Float, nil] duration or nil if not started yet.
    def duration
      return nil unless @started_at

      ((@completed_at || monotonic_time) - @started_at).round(9)
    end

    # Get the worker class name from the Sidekiq job
    # @return [String] worker class name
    def job_worker_class
      ClassHelper.resolve_class_name(@sidekiq_job["class"])
    end

    # Get the job ID from the Sidekiq job.
    # @return [String] job ID
    def jid
      @sidekiq_job["jid"]
    end

    # Re-enqueue the original Sidekiq job
    # @return [String] job ID
    def reenqueue_job
      Sidekiq::Client.push(@sidekiq_job)
    end

    # Called with the HTTP response on a completed request. Note that
    # the response may represent an HTTP error (4xx or 5xx status).
    #
    # @param response [Sidekiq::AsyncHttp::Response] the HTTP response
    # @return [void]
    def success!(response)
      completed! unless completed_at

      @response = response

      worker_class = ClassHelper.resolve_class_name(@completion_worker)
      raise "Completion worker class not set" unless worker_class

      worker_class.set(async_http_continuation: "completion").perform_async(response)
    end

    # Called with the HTTP error on a failed request.
    #
    # @param exception [Exception] the error that occurred
    # @return [void]
    def error!(exception)
      completed! unless completed_at

      @error = exception

      error = Error.from_exception(
        exception,
        request_id: @id,
        duration: duration,
        url: request.url,
        http_method: request.http_method,
        callback_args: @callback_args
      )
      worker_class = ClassHelper.resolve_class_name(@error_worker)
      worker_class.set(async_http_continuation: "error").perform_async(error)
    end

    # Return true if the task successfully received a response from the server.
    # Note that the response may represent an HTTP error (4xx or 5xx status).
    #
    # @return [Boolean]
    def success?
      !@response.nil?
    end

    # Return true if an error was raised during the request.
    #
    # @return [Boolean]
    def error?
      !@error.nil?
    end

    # Build a Response object from async response data.
    #
    # @param status [Integer] HTTP status code
    # @param headers [Hash] HTTP response headers
    # @param body [String, nil] HTTP response body
    # @return [Response] the response object
    # @api private
    def build_response(status:, headers:, body:)
      Response.new(
        status: status,
        headers: headers,
        body: body,
        duration: duration,
        request_id: id,
        url: request.url,
        http_method: request.http_method,
        callback_args: @callback_args
      )
    end
  end
end
