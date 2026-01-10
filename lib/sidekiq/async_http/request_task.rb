# frozen_string_literal: true

module Sidekiq::AsyncHttp
  # Wrapper around a Request to allow it to be enqueued and processed asynchronously.
  class RequestTask
    attr_reader :id, :request, :sidekiq_job, :success_worker, :error_worker,
      :enqueued_at, :started_at, :completed_at

    def initialize(request:, sidekiq_job:, success_worker:, error_worker: nil, enqueued_at: nil)
      @id = SecureRandom.uuid
      @request = request
      @sidekiq_job = sidekiq_job
      @success_worker = success_worker
      @error_worker = error_worker
      @enqueued_at = enqueued_at
      @started_at = nil
      @completed_at = nil
      freeze
    end

    # Enqueued duration in seconds.
    # @return [Float, nil] duration or nil if not enqueued yet.
    def enqueued_duration
      return nil unless @enqueued_at

      (@started_at || Time.now.to_f) - @enqueued_at
    end

    # Execution duration in seconds.
    # @return [Float, nil] duration or nil if not started yet.
    def execution_duration
      return nil unless @started_at

      (@completed_at || Time.now.to_f) - @started_at
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
