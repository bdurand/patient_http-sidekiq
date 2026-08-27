# frozen_string_literal: true

require "spec_helper"
require "support/test_web_server"

RSpec.describe "Crash Recovery", :integration do
  let(:config) do
    PatientHttp::Sidekiq::Configuration.new(
      max_connections: 5,
      heartbeat_interval: 1,
      orphan_threshold: 3
    )
  end
  let(:processor) { PatientHttp::Processor.new(config) }
  let(:stats) { PatientHttp::Sidekiq::Stats.new(config) }
  let(:task_monitor) { PatientHttp::Sidekiq::TaskMonitor.new(config) }
  let(:observer) { PatientHttp::Sidekiq::ProcessorObserver.new(processor, stats: stats, task_monitor: task_monitor) }
  let(:monitor_thread) do
    PatientHttp::Sidekiq::TaskMonitorThread.new(config, task_monitor, -> { processor.tracked_request_ids }, stats: stats)
  end

  around do |example|
    processor.observe(observer)
    monitor_thread.start
    begin
      processor.run do
        example.run
      end
    ensure
      monitor_thread.stop
    end
  end

  it "re-enqueues requests after simulated crash" do
    # Stop the processor and monitor thread so the monitor cannot hold the lock
    processor.stop(timeout: 1)
    monitor_thread.stop

    # Force release any lock
    ::Sidekiq.redis do |redis|
      redis.del(PatientHttp::Sidekiq::TaskMonitor::GC_LOCK_KEY)
    end

    # Create an orphaned request by manually registering and setting old timestamp
    job_payload = {
      "class" => "TestWorker",
      "jid" => "crash-test-jid",
      "args" => [42]
    }

    request = PatientHttp::Request.new(:get, "http://localhost:9876/test")
    task_handler = PatientHttp::Sidekiq::TaskHandler.new(job_payload)

    task = PatientHttp::RequestTask.new(
      request: request,
      task_handler: task_handler,
      callback: TestCallback
    )

    # Register with old timestamp to simulate orphaned request
    task_monitor.register(task)
    old_timestamp_ms = ((Time.now.to_f - 10) * 1000).round
    set_task_timestamp(task_monitor, task, old_timestamp_ms)

    # The collector only re-enqueues requests whose process is gone, so drop
    # the liveness marker the monitor thread wrote for this one.
    expire_process_liveness(task_monitor)

    # Verify it's registered
    expect(task_monitor.registered?(task)).to be true
    expect(PatientHttp::Sidekiq::TaskMonitor.inflight_count).to eq(1)

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
    expect(PatientHttp::Sidekiq::TaskMonitor.inflight_count).to eq(0)

    task_monitor.release_gc_lock
  end

  it "updates heartbeats and prevents false positives" do
    # Create a simple request
    job_payload = {
      "class" => "TestWorker",
      "jid" => "heartbeat-test-jid",
      "args" => []
    }

    request = PatientHttp::Request.new(:get, "http://localhost:9876/test")
    task_handler = PatientHttp::Sidekiq::TaskHandler.new(job_payload)

    task = PatientHttp::RequestTask.new(
      request: request,
      task_handler: task_handler,
      callback: TestCallback
    )

    # Register task (simulating it being in flight)
    task_monitor.register(task)

    # Set an old timestamp
    old_timestamp_ms = ((Time.now.to_f - 2) * 1000).round
    set_task_timestamp(task_monitor, task, old_timestamp_ms)

    # Update heartbeat (simulating monitor thread)
    task_monitor.update_heartbeats([task.id])

    # Try to clean up with 3-second threshold
    expect(Sidekiq::Client).not_to receive(:push)
    count = task_monitor.cleanup_orphaned_requests(3, config.logger)

    # Should not be cleaned up because heartbeat was updated
    expect(count).to eq(0)
    expect(task_monitor.registered?(task)).to be true
    expect(PatientHttp::Sidekiq::TaskMonitor.inflight_count).to eq(1)
  end

  it "handles distributed locking correctly" do
    # Stop the processor and monitor thread so the monitor cannot interfere
    processor.stop(timeout: 1)
    monitor_thread.stop

    # Force release any lock
    ::Sidekiq.redis do |redis|
      redis.del(PatientHttp::Sidekiq::TaskMonitor::GC_LOCK_KEY)
    end

    # Create two task_monitor instances simulating two processes
    task_monitor1 = PatientHttp::Sidekiq::TaskMonitor.new(config)
    task_monitor2 = PatientHttp::Sidekiq::TaskMonitor.new(config)

    # First should acquire lock
    expect(task_monitor1.acquire_gc_lock).to be true

    # Second should fail to acquire
    expect(task_monitor2.acquire_gc_lock).to be false

    # After first releases, second should succeed
    task_monitor1.release_gc_lock
    expect(task_monitor2.acquire_gc_lock).to be true

    task_monitor2.release_gc_lock
  end

  it "registers accepted requests in the registry until the job system owns them again" do
    local_processor = PatientHttp::Processor.new(config)
    local_observer = PatientHttp::Sidekiq::ProcessorObserver.new(
      local_processor,
      stats: PatientHttp::Sidekiq::Stats.new(config),
      task_monitor: PatientHttp::Sidekiq::TaskMonitor.new(config)
    )
    local_processor.observe(local_observer)
    # Never let the reactor consume the queue so the task stays queued.
    allow(local_processor).to receive(:dequeue_request) { |**_args| nil }

    job_payload = {
      "class" => "TestWorker",
      "jid" => "registration-test-jid",
      "args" => []
    }
    request = PatientHttp::Request.new(:get, "http://localhost:9876/test")
    task = PatientHttp::RequestTask.new(
      request: request,
      task_handler: PatientHttp::Sidekiq::TaskHandler.new(job_payload),
      callback: TestCallback
    )

    local_processor.start
    local_processor.enqueue(task)

    # The registry entry is written before enqueue returns, and heartbeats
    # cover the task while it is still queued.
    expect(local_observer.task_monitor.registered?(task)).to be true
    expect(local_processor.tracked_request_ids).to include(task.id)

    pushed_jobs = []
    allow(Sidekiq::Client).to receive(:push) { |job| pushed_jobs << job }

    # Shutdown re-enqueues the queued task as a Sidekiq job and removes the
    # registry entry so crash recovery cannot push the job a second time.
    local_processor.stop(timeout: 0)

    expect(pushed_jobs.size).to eq(1)
    expect(local_observer.task_monitor.registered?(task)).to be false
  ensure
    local_processor&.stop(timeout: 0)
  end

  it "monitor thread updates heartbeats periodically" do
    # Create a task
    job_payload = {
      "class" => "TestWorker",
      "jid" => "monitor-test-jid",
      "args" => []
    }

    request = PatientHttp::Request.new(:get, "http://localhost:9876/test")
    task_handler = PatientHttp::Sidekiq::TaskHandler.new(job_payload)

    task = PatientHttp::RequestTask.new(
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
    fast_config = PatientHttp::Sidekiq::Configuration.new(
      max_connections: 5,
      heartbeat_interval: 1,
      orphan_threshold: 2
    )
    fast_processor = PatientHttp::Processor.new(fast_config)
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
      deadline = Time.now + 6
      while Time.now < deadline && !reenqueued
        sleep(0.1)
      end

      # Job should have been re-enqueued
      expect(reenqueued).to be true
    end
  end
end
