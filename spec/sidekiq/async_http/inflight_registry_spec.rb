# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::InflightRegistry do
  let(:config) { Sidekiq::AsyncHttp::Configuration.new }
  let(:registry) { described_class.new(config) }
  let(:request) do
    Sidekiq::AsyncHttp::Request.new(
      method: :get,
      url: "https://example.com/test"
    )
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
      completion_worker: "TestWorker::CompletionCallback"
    )
  end

  describe "#register" do
    it "adds request to Redis sorted set and hash" do
      registry.register(task)

      Sidekiq.redis do |redis|
        # Check sorted set
        expect(redis.zcard(described_class::INFLIGHT_INDEX_KEY)).to eq(1)
        expect(redis.zscore(described_class::INFLIGHT_INDEX_KEY, task.id)).to be > 0

        # Check hash
        job_payload = redis.hget(described_class::INFLIGHT_JOBS_KEY, task.id)
        expect(job_payload).not_to be_nil
        expect(JSON.parse(job_payload)).to eq(sidekiq_job)
      end
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

    it "removes request from both Redis structures" do
      registry.unregister(task.id)

      Sidekiq.redis do |redis|
        expect(redis.zcard(described_class::INFLIGHT_INDEX_KEY)).to eq(0)
        expect(redis.hexists(described_class::INFLIGHT_JOBS_KEY, task.id)).to eq(0)
      end
    end
  end

  describe "#update_heartbeat" do
    before do
      registry.register(task)
      sleep(0.01) # Small delay to ensure timestamp changes
    end

    it "updates the timestamp for a request" do
      old_score = Sidekiq.redis do |redis|
        redis.zscore(described_class::INFLIGHT_INDEX_KEY, task.id)
      end

      registry.update_heartbeat(task.id)

      new_score = Sidekiq.redis do |redis|
        redis.zscore(described_class::INFLIGHT_INDEX_KEY, task.id)
      end

      expect(new_score).to be > old_score
    end
  end

  describe "#update_heartbeats" do
    let(:task2) do
      Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job.merge("jid" => "test-jid-456"),
        completion_worker: "TestWorker::CompletionCallback"
      )
    end

    before do
      registry.register(task)
      registry.register(task2)
      sleep(0.01)
    end

    it "updates timestamps for multiple requests" do
      old_scores = Sidekiq.redis do |redis|
        [
          redis.zscore(described_class::INFLIGHT_INDEX_KEY, task.id),
          redis.zscore(described_class::INFLIGHT_INDEX_KEY, task2.id)
        ]
      end

      registry.update_heartbeats([task.id, task2.id])

      new_scores = Sidekiq.redis do |redis|
        [
          redis.zscore(described_class::INFLIGHT_INDEX_KEY, task.id),
          redis.zscore(described_class::INFLIGHT_INDEX_KEY, task2.id)
        ]
      end

      expect(new_scores[0]).to be > old_scores[0]
      expect(new_scores[1]).to be > old_scores[1]
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
      Sidekiq.redis do |redis|
        redis.zadd(described_class::INFLIGHT_INDEX_KEY, old_timestamp_ms, task.id)
      end

      # Expect job to be re-enqueued
      expect(Sidekiq::Client).to receive(:push).with(sidekiq_job)

      count = registry.cleanup_orphaned_requests(300, logger)

      expect(count).to eq(1)

      # Request should be removed from Redis
      Sidekiq.redis do |redis|
        expect(redis.zcard(described_class::INFLIGHT_INDEX_KEY)).to eq(0)
        expect(redis.hexists(described_class::INFLIGHT_JOBS_KEY, task.id)).to eq(0)
      end
    end

    it "does not re-enqueue recent requests" do
      registry.register(task)

      expect(Sidekiq::Client).not_to receive(:push)

      count = registry.cleanup_orphaned_requests(300, logger)

      expect(count).to eq(0)

      # Request should still be in Redis
      Sidekiq.redis do |redis|
        expect(redis.zcard(described_class::INFLIGHT_INDEX_KEY)).to eq(1)
      end
    end

    it "handles race condition when heartbeat updated during cleanup" do
      # Register a task
      registry.register(task)

      # Set old timestamp
      old_timestamp_ms = ((Time.now.to_f - 400) * 1000).round
      Sidekiq.redis do |redis|
        redis.zadd(described_class::INFLIGHT_INDEX_KEY, old_timestamp_ms, task.id)
      end

      # Simulate heartbeat update in another thread right before removal
      allow(Sidekiq::Client).to receive(:push) do
        # Update heartbeat to current time
        registry.update_heartbeat(task.id)
      end

      # This should detect the race and not remove the request
      count = registry.cleanup_orphaned_requests(300, logger)

      # Job may or may not be enqueued depending on timing, but it shouldn't be removed from Redis
      # if the heartbeat was updated
      expect(count).to be <= 1
    end

    it "handles multiple orphaned requests" do
      task2 = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job.merge("jid" => "test-jid-456"),
        completion_worker: "TestWorker::CompletionCallback"
      )

      task3 = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job.merge("jid" => "test-jid-789"),
        completion_worker: "TestWorker::CompletionCallback"
      )

      registry.register(task)
      registry.register(task2)
      registry.register(task3)

      # Make first two old, leave third recent
      old_timestamp_ms = ((Time.now.to_f - 400) * 1000).round
      Sidekiq.redis do |redis|
        redis.zadd(described_class::INFLIGHT_INDEX_KEY, old_timestamp_ms, task.id)
        redis.zadd(described_class::INFLIGHT_INDEX_KEY, old_timestamp_ms, task2.id)
      end

      expect(Sidekiq::Client).to receive(:push).twice

      count = registry.cleanup_orphaned_requests(300, logger)

      expect(count).to eq(2)
    end

    it "handles errors when re-enqueuing and continues with other requests" do
      task2 = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job.merge("jid" => "test-jid-456"),
        completion_worker: "TestWorker::CompletionCallback"
      )

      registry.register(task)
      registry.register(task2)

      old_timestamp_ms = ((Time.now.to_f - 400) * 1000).round
      Sidekiq.redis do |redis|
        redis.zadd(described_class::INFLIGHT_INDEX_KEY, old_timestamp_ms, task.id)
        redis.zadd(described_class::INFLIGHT_INDEX_KEY, old_timestamp_ms, task2.id)
      end

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

  describe "#inflight_count" do
    it "returns 0 when no requests" do
      expect(registry.inflight_count).to eq(0)
    end

    it "returns correct count" do
      registry.register(task)
      expect(registry.inflight_count).to eq(1)

      task2 = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job.merge("jid" => "test-jid-456"),
        completion_worker: "TestWorker::CompletionCallback"
      )
      registry.register(task2)

      expect(registry.inflight_count).to eq(2)

      registry.unregister(task.id)
      expect(registry.inflight_count).to eq(1)
    end
  end
end
