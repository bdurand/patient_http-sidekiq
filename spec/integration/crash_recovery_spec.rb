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
  let(:processor) { AsyncHttpPool::Processor.new(config) }
  let(:observer) { Sidekiq::AsyncHttp::ProcessorObserver.new(processor) }
  let(:task_monitor) { observer.task_monitor }
  let(:web_server) { TestWebServer.new }

  around do |example|
    processor.observe(observer)
    processor.run do
      example.run
    end
  end

  it "re-enqueues requests after simulated crash" do
    # Stop processor to prevent monitor thread from holding lock
    processor.stop(timeout: 1)

    # Force release any lock
    Sidekiq.redis do |redis|
      redis.del(Sidekiq::AsyncHttp::TaskMonitor::GC_LOCK_KEY)
    end

    # Create an orphaned request by manually registering and setting old timestamp
    job_payload = {
      "class" => "TestWorker",
      "jid" => "crash-test-jid",
      "args" => [42]
    }

    request = AsyncHttpPool::Request.new(:get, "http://localhost:9876/test")
    task_handler = Sidekiq::AsyncHttp::SidekiqTaskHandler.new(job_payload)

    task = AsyncHttpPool::RequestTask.new(
      request: request,
      task_handler: task_handler,
      callback: TestCallback
    )

    # Register with old timestamp to simulate orphaned request
    task_monitor.register(task)
    old_timestamp_ms = ((Time.now.to_f - 10) * 1000).round
    set_task_timestamp(task_monitor, task, old_timestamp_ms)

    # Verify it's registered
    expect(task_monitor.registered?(task)).to be true
    expect(Sidekiq::AsyncHttp::TaskMonitor.inflight_count).to eq(1)

    # Mock Sidekiq::Client to capture re-enqueued job
    reenqueued_jobs = []
    allow(Sidekiq::Client).to receive(:push) do |job|
      reenqueued_jobs << job
    end

    # Acquire GC lock and run cleanup
    expect(task_monitor.acquire_gc_lock).to be true
    count = task_monitor.cleanup_orphaned_requests(3, config.logger)

    expect(count).to eq(1)
    expect(reenqueued_jobs.size).to eq(1)
    expect(reenqueued_jobs.first["jid"]).to eq("crash-test-jid")

    # Verify it's removed from task_monitor
    expect(task_monitor.registered?(task)).to be false
    expect(Sidekiq::AsyncHttp::TaskMonitor.inflight_count).to eq(0)

    task_monitor.release_gc_lock
  end

  it "updates heartbeats and prevents false positives" do
    # Create a simple request
    job_payload = {
      "class" => "TestWorker",
      "jid" => "heartbeat-test-jid",
      "args" => []
    }

    request = AsyncHttpPool::Request.new(:get, "http://localhost:9876/test")
    task_handler = Sidekiq::AsyncHttp::SidekiqTaskHandler.new(job_payload)

    task = AsyncHttpPool::RequestTask.new(
      request: request,
      task_handler: task_handler,
      callback: TestCallback
    )

    # Register task (simulating it being in flight)
    task_monitor.register(task)
    full_task_id = task_monitor.full_task_id(task.id)

    # Set an old timestamp
    old_timestamp_ms = ((Time.now.to_f - 2) * 1000).round
    set_task_timestamp(task_monitor, task, old_timestamp_ms)

    # Update heartbeat (simulating monitor thread)
    task_monitor.update_heartbeats([full_task_id])

    # Try to clean up with 3-second threshold
    expect(Sidekiq::Client).not_to receive(:push)
    count = task_monitor.cleanup_orphaned_requests(3, config.logger)

    # Should not be cleaned up because heartbeat was updated
    expect(count).to eq(0)
    expect(task_monitor.registered?(task)).to be true
    expect(Sidekiq::AsyncHttp::TaskMonitor.inflight_count).to eq(1)
  end

  it "handles distributed locking correctly" do
    # Stop processor to prevent monitor thread from interfering
    processor.stop(timeout: 1)

    # Force release any lock
    Sidekiq.redis do |redis|
      redis.del(Sidekiq::AsyncHttp::TaskMonitor::GC_LOCK_KEY)
    end

    # Create two task_monitor instances simulating two processes
    task_monitor1 = Sidekiq::AsyncHttp::TaskMonitor.new(config)
    task_monitor2 = Sidekiq::AsyncHttp::TaskMonitor.new(config)

    # First should acquire lock
    expect(task_monitor1.acquire_gc_lock).to be true

    # Second should fail to acquire
    expect(task_monitor2.acquire_gc_lock).to be false

    # After first releases, second should succeed
    task_monitor1.release_gc_lock
    expect(task_monitor2.acquire_gc_lock).to be true

    task_monitor2.release_gc_lock
  end

  it "monitor thread updates heartbeats periodically" do
    # Create a task
    job_payload = {
      "class" => "TestWorker",
      "jid" => "monitor-test-jid",
      "args" => []
    }

    request = AsyncHttpPool::Request.new(:get, "http://localhost:9876/test")
    task_handler = Sidekiq::AsyncHttp::SidekiqTaskHandler.new(job_payload)

    task = AsyncHttpPool::RequestTask.new(
      request: request,
      task_handler: task_handler,
      callback: TestCallback
    )

    # Register in Redis
    task_monitor.register(task)

    # Manually add to processor's inflight tracking
    processor.instance_variable_get(:@inflight_requests)[task.id] = task

    # Get initial timestamp
    initial_timestamp = task_monitor.heartbeat_timestamp_for(task)

    # Wait for monitor to update (heartbeat_interval is 1 second)
    sleep(1.2)

    # Get new timestamp
    new_timestamp = task_monitor.heartbeat_timestamp_for(task)

    # Timestamp should have been updated
    expect(new_timestamp).to be > initial_timestamp

    # Clean up
    processor.instance_variable_get(:@inflight_requests).delete(task.id)
    task_monitor.unregister(task)
  end

  it "performs garbage collection automatically via monitor thread" do
    # Configure with shorter intervals for faster testing
    fast_config = Sidekiq::AsyncHttp::Configuration.new(
      max_connections: 5,
      heartbeat_interval: 1,
      orphan_threshold: 2
    )
    fast_processor = AsyncHttpPool::Processor.new(fast_config)
    fast_processor.run do
      # Create an orphaned request that appears to be from a different (crashed) process
      job_payload = {
        "class" => "TestWorker",
        "jid" => "gc-test-jid",
        "args" => []
      }

      # Simulate an orphaned task from a crashed process
      old_timestamp_ms = ((Time.now.to_f - 10) * 1000).round
      add_fake_orphaned_request(
        process_id: "crashed-host:12345:abcdef12",
        request_id: "fake-request-id",
        job_payload: job_payload,
        timestamp_ms: old_timestamp_ms
      )

      # Mock job re-enqueue
      reenqueued = false
      allow(Sidekiq::Client).to receive(:push) do |job|
        reenqueued = true if job["jid"] == "gc-test-jid"
      end

      # Wait for monitor to run GC (up to 5 seconds)
      deadline = Time.now + 5
      while Time.now < deadline && !reenqueued
        sleep(0.1)
      end

      # Job should have been re-enqueued
      expect(reenqueued).to be true
    end
  end
end
