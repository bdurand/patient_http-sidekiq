# frozen_string_literal: true

# Test helpers for InflightRegistry specs.
#
# These helpers allow tests to manipulate Redis state directly for setting up
# test scenarios (e.g., simulating old timestamps for orphaned requests).
module InflightRegistryHelpers
  # Set a task's timestamp in the inflight registry.
  # Used to simulate old requests that should be considered orphaned.
  #
  # @param registry [Sidekiq::AsyncHttp::InflightRegistry] the registry instance
  # @param task [Sidekiq::AsyncHttp::RequestTask] the task to update
  # @param timestamp_ms [Integer] the timestamp in milliseconds
  def set_task_timestamp(registry, task, timestamp_ms)
    full_task_id = registry.task_id(task)
    Sidekiq.redis do |redis|
      redis.zadd(Sidekiq::AsyncHttp::InflightRegistry::INFLIGHT_INDEX_KEY,
        timestamp_ms, full_task_id)
    end
  end

  # Set a raw task ID's timestamp in the inflight registry.
  # Used for simulating orphaned requests from crashed processes.
  #
  # @param task_id [String] the full task ID
  # @param timestamp_ms [Integer] the timestamp in milliseconds
  def set_raw_task_timestamp(task_id, timestamp_ms)
    Sidekiq.redis do |redis|
      redis.zadd(Sidekiq::AsyncHttp::InflightRegistry::INFLIGHT_INDEX_KEY,
        timestamp_ms, task_id)
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
    Sidekiq.redis do |redis|
      redis.zadd(Sidekiq::AsyncHttp::InflightRegistry::INFLIGHT_INDEX_KEY,
        timestamp_ms, full_task_id)
      redis.hset(Sidekiq::AsyncHttp::InflightRegistry::INFLIGHT_JOBS_KEY,
        full_task_id, job_payload.to_json)
    end
    full_task_id
  end

  # Get the raw timestamp for a task from Redis.
  #
  # @param registry [Sidekiq::AsyncHttp::InflightRegistry] the registry instance
  # @param task [Sidekiq::AsyncHttp::RequestTask] the task
  # @return [Float, nil] the timestamp as a float, or nil if not found
  def get_raw_task_timestamp(registry, task)
    full_task_id = registry.task_id(task)
    Sidekiq.redis do |redis|
      redis.zscore(Sidekiq::AsyncHttp::InflightRegistry::INFLIGHT_INDEX_KEY, full_task_id)
    end
  end
end

RSpec.configure do |config|
  config.include InflightRegistryHelpers
end
