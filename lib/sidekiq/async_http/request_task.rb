# frozen_string_literal: true

module Sidekiq::AsyncHttp
  # Wrapper around a Request to allow it to be enqueued and processed asynchronously.
  class RequestTask
    include TimeHelper

    attr_reader :id, :request, :sidekiq_job, :success_worker, :error_worker

    def initialize(request:, sidekiq_job:, success_worker:, error_worker: nil)
      @id = SecureRandom.uuid
      @request = request
      @sidekiq_job = sidekiq_job
      @success_worker = success_worker
      @error_worker = error_worker
      @enqueued_at = nil
      @started_at = nil
      @completed_at = nil
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

    def enqueued_at
      wall_clock_time(@enqueued_at) if @enqueued_at
    end

    def started_at
      wall_clock_time(@started_at) if @started_at
    end

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

      (@completed_at || monotonic_time) - @started_at
    end

    # Get the worker class name from the Sidekiq job
    # @return [String] worker class name
    def job_worker_class
      @sidekiq_job["class"].split("::").reduce(Object) { |mod, name| mod.const_get(name) }
    end

    # Get the job ID from the Sidekiq job.
    # @return [String] job ID
    def jid
      @sidekiq_job["jid"]
    end

    # Get the arguments from the Sidekiq job
    # @return [Array] job arguments
    def job_args
      @sidekiq_job["args"]
    end

    # Re-enqueue the original Sidekiq job
    # @return [String] job ID
    def reenqueue_job
      Sidekiq::Client.push(@sidekiq_job)
    end

    # Retry the original Sidekiq job with incremented retry count
    # @return [String] job ID
    def retry_job
      @sidekiq_job["retry_count"] = (@sidekiq_job["retry_count"] || 0) + 1
      Sidekiq::Client.push(@sidekiq_job)
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
