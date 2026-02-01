# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::InflightRegistry do
  let(:config) { Sidekiq::AsyncHttp::Configuration.new }
  let(:registry) { described_class.new(config) }
  let(:request) do
    Sidekiq::AsyncHttp::Request.new(:get, "https://example.com/test")
  end
  let(:sidekiq_job) do
    {
      "class" => "TestWorker",
      "jid" => "test-jid-123",
      "args" => [1, 2, 3]
    }
  end
  let(:task) do
    Sidekiq::AsyncHttp::RequestTask.new(
      request: request,
      sidekiq_job: sidekiq_job,
      callback: TestCallback
    )
  end

  describe "#register" do
    it "adds request to registry" do
      registry.register(task)

      expect(registry.registered?(task)).to be true
      expect(described_class.inflight_count).to eq(1)
      expect(registry.heartbeat_timestamp_for(task)).to be > 0
    end

    it "sets TTL on both keys" do
      registry.register(task)

      Sidekiq.redis do |redis|
        index_ttl = redis.ttl(described_class::INFLIGHT_INDEX_KEY)
        jobs_ttl = redis.ttl(described_class::INFLIGHT_JOBS_KEY)

        # TTL should be set to at least 3x the orphan threshold (900 seconds with default config)
        expected_min_ttl = config.orphan_threshold * 3
        expect(index_ttl).to be > 0
        expect(index_ttl).to be >= expected_min_ttl - 5 # Allow 5 second tolerance
        expect(jobs_ttl).to be > 0
        expect(jobs_ttl).to be >= expected_min_ttl - 5
      end
    end
  end

  describe "#unregister" do
    before do
      registry.register(task)
    end

    it "removes request from registry" do
      registry.unregister(task)

      expect(registry.registered?(task)).to be false
      expect(described_class.inflight_count).to eq(0)
    end
  end

  describe "#update_heartbeats" do
    let(:task2) do
      Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job.merge("jid" => "test-jid-456"),
        callback: TestCallback
      )
    end

    before do
      registry.register(task)
      registry.register(task2)
      sleep(0.01)
    end

    it "updates timestamps for multiple requests" do
      full_task_id = registry.task_id(task)
      full_task_id2 = registry.task_id(task2)

      old_timestamps = [
        registry.heartbeat_timestamp_for(task),
        registry.heartbeat_timestamp_for(task2)
      ]

      registry.update_heartbeats([full_task_id, full_task_id2])

      new_timestamps = [
        registry.heartbeat_timestamp_for(task),
        registry.heartbeat_timestamp_for(task2)
      ]

      expect(new_timestamps[0]).to be > old_timestamps[0]
      expect(new_timestamps[1]).to be > old_timestamps[1]
    end

    it "handles empty array" do
      expect { registry.update_heartbeats([]) }.not_to raise_error
    end
  end

  describe "#acquire_gc_lock" do
    it "acquires lock when not held" do
      expect(registry.acquire_gc_lock).to be true
    end

    it "fails to acquire lock when already held" do
      expect(registry.acquire_gc_lock).to be true
      expect(registry.acquire_gc_lock).to be false
    end

    it "can acquire lock after TTL expires" do
      expect(registry.acquire_gc_lock).to be true

      # Manually expire the lock
      Sidekiq.redis do |redis|
        redis.del(described_class::GC_LOCK_KEY)
      end

      expect(registry.acquire_gc_lock).to be true
    end
  end

  describe "#release_gc_lock" do
    it "releases lock held by this process" do
      # Explicitly ensure no lock exists from previous test
      Sidekiq.redis do |redis|
        redis.del(described_class::GC_LOCK_KEY)
      end

      result1 = registry.acquire_gc_lock
      expect(result1).to be true

      registry.release_gc_lock

      # Should be able to acquire again
      result2 = registry.acquire_gc_lock
      expect(result2).to be true
    end

    it "does not release lock held by another process" do
      registry.acquire_gc_lock

      # Create another registry instance (simulating another process)
      other_registry = described_class.new(config)
      other_registry.release_gc_lock

      # Lock should still be held
      expect(other_registry.acquire_gc_lock).to be false
    end
  end

  describe "#cleanup_orphaned_requests" do
    let(:logger) { instance_double(Logger, info: nil, error: nil) }

    it "re-enqueues requests older than threshold" do
      # Register a task
      registry.register(task)

      # Manually set its timestamp to be old
      old_timestamp_ms = ((Time.now.to_f - 400) * 1000).round
      set_task_timestamp(registry, task, old_timestamp_ms)

      # Expect job to be re-enqueued
      expect(Sidekiq::Client).to receive(:push).with(sidekiq_job)

      count = registry.cleanup_orphaned_requests(300, logger)

      expect(count).to eq(1)

      # Request should be removed from registry
      expect(registry.registered?(task)).to be false
      expect(described_class.inflight_count).to eq(0)
    end

    it "does not re-enqueue recent requests" do
      registry.register(task)

      expect(Sidekiq::Client).not_to receive(:push)

      count = registry.cleanup_orphaned_requests(300, logger)

      expect(count).to eq(0)

      # Request should still be in registry
      expect(registry.registered?(task)).to be true
      expect(described_class.inflight_count).to eq(1)
    end

    it "handles race condition atomically with Lua script" do
      # Register a task
      registry.register(task)
      registry.task_id(task)

      # Set old timestamp
      old_timestamp_ms = ((Time.now.to_f - 400) * 1000).round
      set_task_timestamp(registry, task, old_timestamp_ms)

      # The Lua script atomically checks and removes, so there's no race window.
      # This test verifies the atomic behavior by checking that exactly one
      # re-enqueue happens when the task is orphaned.
      expect(Sidekiq::Client).to receive(:push).once.with(sidekiq_job)

      count = registry.cleanup_orphaned_requests(300, logger)

      expect(count).to eq(1)
      expect(registry.registered?(task)).to be false
    end

    it "handles multiple orphaned requests" do
      task2 = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job.merge("jid" => "test-jid-456"),
        callback: TestCallback
      )

      task3 = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job.merge("jid" => "test-jid-789"),
        callback: TestCallback
      )

      registry.register(task)
      registry.register(task2)
      registry.register(task3)

      # Make first two old, leave third recent
      old_timestamp_ms = ((Time.now.to_f - 400) * 1000).round
      set_task_timestamp(registry, task, old_timestamp_ms)
      set_task_timestamp(registry, task2, old_timestamp_ms)

      expect(Sidekiq::Client).to receive(:push).twice

      count = registry.cleanup_orphaned_requests(300, logger)

      expect(count).to eq(2)
    end

    it "handles errors when re-enqueuing and continues with other requests" do
      task2 = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job.merge("jid" => "test-jid-456"),
        callback: TestCallback
      )

      registry.register(task)
      registry.register(task2)

      old_timestamp_ms = ((Time.now.to_f - 400) * 1000).round
      set_task_timestamp(registry, task, old_timestamp_ms)
      set_task_timestamp(registry, task2, old_timestamp_ms)

      # First push fails, second succeeds
      call_count = 0
      allow(Sidekiq::Client).to receive(:push) do
        call_count += 1
        raise "Push failed" if call_count == 1
      end

      expect(logger).to receive(:error).once

      count = registry.cleanup_orphaned_requests(300, logger)

      expect(count).to eq(1)
    end
  end

  describe "#ping_process" do
    it "adds process to the process set" do
      registry.ping_process

      expect(described_class.registered_process_ids.size).to eq(1)
    end

    it "stores max connections for the process" do
      registry.ping_process

      max_conn = described_class.total_max_connections
      expect(max_conn).to eq(config.max_connections)
    end
  end

  describe ".inflight_counts_by_process" do
    it "returns all inflight counts and max connections" do
      registry.ping_process
      registry.register(task)

      all_inflight = described_class.inflight_counts_by_process
      expect(all_inflight).to be_a(Hash)
      expect(all_inflight.size).to eq(1)
      expect(all_inflight.values.first[:inflight]).to eq(1)
      expect(all_inflight.values.first[:max_capacity]).to eq(config.max_connections)
    end

    it "returns empty hash when no inflight data" do
      all_inflight = described_class.inflight_counts_by_process
      expect(all_inflight).to eq({})
    end

    it "removes stale process entries" do
      # Add a fake process entry without corresponding max_connections key
      Sidekiq.redis do |redis|
        redis.sadd(described_class::PROCESS_SET_KEY, "stale_process_id")
      end

      all_inflight = described_class.inflight_counts_by_process
      expect(all_inflight).to eq({})

      # Verify the stale entry was removed
      expect(described_class.registered_process_ids).not_to include("stale_process_id")
    end
  end

  describe ".inflight_count" do
    it "sums all inflight counts" do
      registry.ping_process
      registry.register(task)

      total = described_class.inflight_count
      expect(total).to eq(1)
    end

    it "returns 0 when no inflight data" do
      total = described_class.inflight_count
      expect(total).to eq(0)
    end
  end

  describe ".total_max_connections" do
    it "sums all max connections" do
      registry.ping_process

      total = described_class.total_max_connections
      expect(total).to eq(config.max_connections)
    end

    it "returns 0 when no max connections data" do
      total = described_class.total_max_connections
      expect(total).to eq(0)
    end

    it "removes stale process entries" do
      # Add a fake process entry without corresponding max_connections key
      Sidekiq.redis do |redis|
        redis.sadd(described_class::PROCESS_SET_KEY, "stale_process_id")
      end

      total = described_class.total_max_connections
      expect(total).to eq(0)

      # Verify the stale entry was removed
      expect(described_class.registered_process_ids).not_to include("stale_process_id")
    end
  end

  describe "#inflight_count" do
    it "returns 0 when no requests" do
      expect(described_class.inflight_count).to eq(0)
    end

    it "returns correct count" do
      registry.register(task)
      expect(described_class.inflight_count).to eq(1)

      task2 = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job.merge("jid" => "test-jid-456"),
        callback: TestCallback
      )
      registry.register(task2)

      expect(described_class.inflight_count).to eq(2)

      registry.unregister(task)
      expect(described_class.inflight_count).to eq(1)
    end
  end

  describe "#registered?" do
    it "returns false for unregistered task" do
      expect(registry.registered?(task)).to be false
    end

    it "returns true for registered task" do
      registry.register(task)
      expect(registry.registered?(task)).to be true
    end

    it "returns false after task is unregistered" do
      registry.register(task)
      registry.unregister(task)
      expect(registry.registered?(task)).to be false
    end
  end

  describe "#heartbeat_timestamp_for" do
    it "returns nil for unregistered task" do
      expect(registry.heartbeat_timestamp_for(task)).to be_nil
    end

    it "returns timestamp for registered task" do
      registry.register(task)
      timestamp = registry.heartbeat_timestamp_for(task)

      expect(timestamp).to be_a(Integer)
      expect(timestamp).to be > 0
    end

    it "returns updated timestamp after heartbeat" do
      registry.register(task)
      old_timestamp = registry.heartbeat_timestamp_for(task)

      sleep(0.01)
      registry.update_heartbeats([registry.task_id(task)])

      new_timestamp = registry.heartbeat_timestamp_for(task)
      expect(new_timestamp).to be > old_timestamp
    end
  end

  describe "#registered_task_ids" do
    it "returns empty array when no tasks registered" do
      expect(registry.registered_task_ids).to eq([])
    end

    it "returns task IDs for this registry only" do
      registry.register(task)

      task2 = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job.merge("jid" => "test-jid-456"),
        callback: TestCallback
      )
      registry.register(task2)

      task_ids = registry.registered_task_ids
      expect(task_ids.size).to eq(2)
      expect(task_ids).to include(registry.task_id(task))
      expect(task_ids).to include(registry.task_id(task2))
    end

    it "does not include tasks from other registries" do
      registry.register(task)

      other_registry = described_class.new(config)
      other_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job.merge("jid" => "other-jid"),
        callback: TestCallback
      )
      other_registry.register(other_task)

      expect(registry.registered_task_ids.size).to eq(1)
      expect(other_registry.registered_task_ids.size).to eq(1)
    end
  end

  describe ".registered_process_ids" do
    it "returns empty array when no processes registered" do
      expect(described_class.registered_process_ids).to eq([])
    end

    it "returns process IDs after ping" do
      registry.ping_process

      process_ids = described_class.registered_process_ids
      expect(process_ids.size).to eq(1)
    end
  end

  describe ".clear_all!" do
    it "clears all registry data" do
      registry.ping_process
      registry.register(task)
      registry.acquire_gc_lock

      expect(described_class.inflight_count).to eq(1)
      expect(described_class.registered_process_ids.size).to eq(1)

      described_class.clear_all!

      expect(described_class.inflight_count).to eq(0)
      expect(described_class.registered_process_ids).to eq([])
    end
  end
end
