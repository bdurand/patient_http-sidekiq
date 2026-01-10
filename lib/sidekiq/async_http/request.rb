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
    attr_reader :id, :request, :enqueued_at

    def initialize(request)
      @id = SecureRandom.uuid
      @request = request
      @job = nil
      @success_worker_class = nil
      @error_worker_class = nil
      @enqueued_at = nil
    end

    # Prepare the request for execution with callback workers.
    #
    # @param sidekiq_job [Hash] Sidekiq job hash with "class" and "args" keys.
    #   If not provided, uses Sidekiq::Context.current (Sidekiq 8+).
    # @param success_worker [String] Worker class name to call on successful response
    # @param error_worker [String, nil] Worker class name to call on error.
    #   If nil, errors will be logged and the original job will be retried.
    # @return [void]
    def perform(sidekiq_job:, success_worker:, error_worker: nil)
      @job = sidekiq_job
      @success_worker_class = success_worker
      @error_worker_class = error_worker
      @enqueued_at = Time.now.to_f
    end

    # Get the worker class name from the Sidekiq job
    # @return [String] worker class name
    def job_worker_class
      @job["class"]
    end

    # Get the arguments from the Sidekiq job
    # @return [Array] job arguments
    def job_args
      @job["args"]
    end

    # Re-enqueue the original Sidekiq job
    # @return [String] job ID
    def reenqueue_job
      Sidekiq::Client.push(@job)
    end

    # Retry the original Sidekiq job with incremented retry count
    # @return [String] job ID
    def retry_job
      @job["retry_count"] = (@job["retry_count"] || 0) + 1
      Sidekiq::Client.push(@job)
    end

    # Called when the HTTP request succeeds
    # @param response [Hash] response data
    # @return [void]
    def success(response)
    end

    # Called when the HTTP request fails
    # @param error [Error] error object
    # @return [void]
    def error(error)
    end
  end
end
