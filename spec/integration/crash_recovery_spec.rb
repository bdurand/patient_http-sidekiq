# frozen_string_literal: true

require "spec_helper"
require "support/test_web_server"

RSpec.describe "Crash Recovery", :integration do
  let(:config) do
    Sidekiq::AsyncHttp::Configuration.new(
      max_connections: 5,
      heartbeat_interval: 1,
      orphan_threshold: 3
    )
  end
  let(:processor) { Sidekiq::AsyncHttp::Processor.new(config) }
  let(:registry) { processor.inflight_registry }
  let(:web_server) { TestWebServer.new }

  around do |example|
    processor.run do
      example.run
    end
  end

  it "re-enqueues requests after simulated crash" do
    # Stop processor to prevent monitor thread from holding lock
    processor.stop(timeout: 1)

    # Force release any lock
    Sidekiq.redis do |redis|
      redis.del(Sidekiq::AsyncHttp::InflightRegistry::GC_LOCK_KEY)
    end

    # Create an orphaned request by manually registering and setting old timestamp
    job_payload = {
      "class" => "TestWorker",
      "jid" => "crash-test-jid",
      "args" => [42]
    }

    request = Sidekiq::AsyncHttp::Request.new(:get, "http://localhost:9876/test")

    task = Sidekiq::AsyncHttp::RequestTask.new(
      request: request,
      sidekiq_job: job_payload,
      completion_worker: "TestWorker::CompletionCallback"
    )

    # Register with old timestamp to simulate orphaned request
    registry.register(task)
    old_timestamp_ms = ((Time.now.to_f - 10) * 1000).round
    Sidekiq.redis do |redis|
      redis.zadd(Sidekiq::AsyncHttp::InflightRegistry::INFLIGHT_INDEX_KEY, old_timestamp_ms, task.id)
    end

    # Verify it's registered
    expect(registry.inflight_count).to eq(1)

    # Mock Sidekiq::Client to capture re-enqueued job
    reenqueued_jobs = []
    allow(Sidekiq::Client).to receive(:push) do |job|
      reenqueued_jobs << job
    end

    # Acquire GC lock and run cleanup
    expect(registry.acquire_gc_lock).to be true
    count = registry.cleanup_orphaned_requests(3, config.logger)

    expect(count).to eq(1)
    expect(reenqueued_jobs.size).to eq(1)
    expect(reenqueued_jobs.first["jid"]).to eq("crash-test-jid")

    # Verify it's removed from Redis
    expect(registry.inflight_count).to eq(0)

    registry.release_gc_lock
  end

  it "updates heartbeats and prevents false positives" do
    # Create a simple request
    job_payload = {
      "class" => "TestWorker",
      "jid" => "heartbeat-test-jid",
      "args" => []
    }

    request = Sidekiq::AsyncHttp::Request.new(:get, "http://localhost:9876/test")

    task = Sidekiq::AsyncHttp::RequestTask.new(
      request: request,
      sidekiq_job: job_payload,
      completion_worker: "TestWorker::CompletionCallback"
    )

    # Register task (simulating it being in flight)
    registry.register(task)

    # Set an old timestamp
    old_timestamp_ms = ((Time.now.to_f - 2) * 1000).round
    Sidekiq.redis do |redis|
      redis.zadd(Sidekiq::AsyncHttp::InflightRegistry::INFLIGHT_INDEX_KEY, old_timestamp_ms, task.id)
    end

    # Update heartbeat (simulating monitor thread)
    registry.update_heartbeat(task.id)

    # Try to clean up with 3-second threshold
    expect(Sidekiq::Client).not_to receive(:push)
    count = registry.cleanup_orphaned_requests(3, config.logger)

    # Should not be cleaned up because heartbeat was updated
    expect(count).to eq(0)
    expect(registry.inflight_count).to eq(1)
  end

  it "handles distributed locking correctly" do
    # Stop processor to prevent monitor thread from interfering
    processor.stop(timeout: 1)

    # Force release any lock
    Sidekiq.redis do |redis|
      redis.del(Sidekiq::AsyncHttp::InflightRegistry::GC_LOCK_KEY)
    end

    # Create two registry instances simulating two processes
    registry1 = Sidekiq::AsyncHttp::InflightRegistry.new(config)
    registry2 = Sidekiq::AsyncHttp::InflightRegistry.new(config)

    # First should acquire lock
    expect(registry1.acquire_gc_lock).to be true

    # Second should fail to acquire
    expect(registry2.acquire_gc_lock).to be false

    # After first releases, second should succeed
    registry1.release_gc_lock
    expect(registry2.acquire_gc_lock).to be true

    registry2.release_gc_lock
  end

  it "monitor thread updates heartbeats periodically" do
    # Create a task
    job_payload = {
      "class" => "TestWorker",
      "jid" => "monitor-test-jid",
      "args" => []
    }

    request = Sidekiq::AsyncHttp::Request.new(:get, "http://localhost:9876/test")

    task = Sidekiq::AsyncHttp::RequestTask.new(
      request: request,
      sidekiq_job: job_payload,
      completion_worker: "TestWorker::CompletionCallback"
    )

    # Register in Redis
    registry.register(task)

    # Manually add to processor's inflight tracking
    processor.instance_variable_get(:@inflight_requests)[task.id] = task

    # Get initial timestamp
    initial_score = Sidekiq.redis do |redis|
      redis.zscore(Sidekiq::AsyncHttp::InflightRegistry::INFLIGHT_INDEX_KEY, task.id)
    end

    # Wait for monitor to update (heartbeat_interval is 1 second)
    sleep(1.5)

    # Get new timestamp
    new_score = Sidekiq.redis do |redis|
      redis.zscore(Sidekiq::AsyncHttp::InflightRegistry::INFLIGHT_INDEX_KEY, task.id)
    end

    # Timestamp should have been updated
    expect(new_score).to be > initial_score

    # Clean up
    processor.instance_variable_get(:@inflight_requests).delete(task.id)
    registry.unregister(task.id)
  end

  it "performs garbage collection automatically via monitor thread" do
    # Configure with shorter intervals for faster testing
    fast_config = Sidekiq::AsyncHttp::Configuration.new(
      max_connections: 5,
      heartbeat_interval: 1,
      orphan_threshold: 2
    )
    fast_processor = Sidekiq::AsyncHttp::Processor.new(fast_config)
    fast_registry = fast_processor.inflight_registry
    fast_processor.run do
      # Create an orphaned request
      job_payload = {
        "class" => "TestWorker",
        "jid" => "gc-test-jid",
        "args" => []
      }

      request = Sidekiq::AsyncHttp::Request.new(:get, "http://localhost:9876/test")

      task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: job_payload,
        completion_worker: "TestWorker::CompletionCallback"
      )

      # Register with old timestamp
      fast_registry.register(task)
      old_timestamp_ms = ((Time.now.to_f - 10) * 1000).round
      Sidekiq.redis do |redis|
        redis.zadd(Sidekiq::AsyncHttp::InflightRegistry::INFLIGHT_INDEX_KEY, old_timestamp_ms, task.id)
      end

      # Mock job re-enqueue
      reenqueued = false
      allow(Sidekiq::Client).to receive(:push) do |job|
        reenqueued = true if job["jid"] == "gc-test-jid"
      end

      # Wait for monitor to run GC (up to 3 seconds)
      deadline = Time.now + 3
      while Time.now < deadline && !reenqueued
        sleep(0.1)
      end

      # Job should have been re-enqueued
      expect(reenqueued).to be true
    end
  end
end
