# frozen_string_literal: true

# Test helpers for TaskMonitor specs.
#
# These helpers allow tests to manipulate Redis state directly for setting up
# test scenarios (e.g., simulating old timestamps for orphaned requests).
module TaskMonitorHelpers
  # Set a task's timestamp in the inflight registry.
  # Used to simulate old requests that should be considered orphaned.
  #
  # @param registry [PatientHttp::Sidekiq::TaskMonitor] the registry instance
  # @param task [PatientHttp::RequestTask] the task to update
  # @param timestamp_ms [Integer] the timestamp in milliseconds
  def set_task_timestamp(registry, task, timestamp_ms)
    full_task_id = registry.full_task_id(task.id)
    ::Sidekiq.redis do |redis|
      redis.zadd(PatientHttp::Sidekiq::TaskMonitor::INFLIGHT_INDEX_KEY,
        timestamp_ms, full_task_id)
    end
  end

  # Remove a registry's process liveness marker, which is what the orphan
  # collector sees once the process that wrote it is gone. A registry that has
  # pinged recently is still considered live, and requests registered by a live
  # process are never treated as orphaned.
  #
  # @param registry [PatientHttp::Sidekiq::TaskMonitor] the registry instance
  def expire_process_liveness(registry)
    process_id = registry.instance_variable_get(:@lock_identifier)
    ::Sidekiq.redis do |redis|
      redis.del("#{PatientHttp::Sidekiq::TaskMonitor::PROCESS_SET_KEY}:#{process_id}:max_connections")
    end
  end

  # Add a fake orphaned request to Redis (simulating a crashed process).
  #
  # @param process_id [String] the fake process identifier
  # @param request_id [String] the request ID portion
  # @param job_payload [Hash] the job payload
  # @param timestamp_ms [Integer] the timestamp in milliseconds
  # @return [String] the full task ID
  def add_fake_orphaned_request(process_id:, request_id:, job_payload:, timestamp_ms:)
    full_task_id = "#{process_id}/#{request_id}"
    ::Sidekiq.redis do |redis|
      redis.zadd(PatientHttp::Sidekiq::TaskMonitor::INFLIGHT_INDEX_KEY,
        timestamp_ms, full_task_id)
      redis.hset(PatientHttp::Sidekiq::TaskMonitor::INFLIGHT_JOBS_KEY,
        full_task_id, job_payload.to_json)
    end
    full_task_id
  end
end

RSpec.configure do |config|
  config.include TaskMonitorHelpers
end
