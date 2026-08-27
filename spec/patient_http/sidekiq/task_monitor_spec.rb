# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::TaskMonitor do
  let(:config) { PatientHttp::Sidekiq::Configuration.new }
  let(:registry) { described_class.new(config) }
  let(:request) do
    PatientHttp::Request.new(:get, "https://example.com/test")
  end
  let(:sidekiq_job) do
    {
      "class" => "TestWorker",
      "jid" => "test-jid-123",
      "args" => [1, 2, 3]
    }
  end
  let(:task_handler) { PatientHttp::Sidekiq::TaskHandler.new(sidekiq_job) }
  let(:task) do
    PatientHttp::RequestTask.new(
      request: request,
      task_handler: task_handler,
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

      ::Sidekiq.redis do |redis|
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
      handler2 = PatientHttp::Sidekiq::TaskHandler.new(sidekiq_job.merge("jid" => "test-jid-456"))
      PatientHttp::RequestTask.new(
        request: request,
        task_handler: handler2,
        callback: TestCallback
      )
    end

    before do
      registry.register(task)
      registry.register(task2)
      sleep(0.01)
    end

    it "updates timestamps for multiple requests" do
      old_timestamps = [
        registry.heartbeat_timestamp_for(task),
        registry.heartbeat_timestamp_for(task2)
      ]

      registry.update_heartbeats([task.id, task2.id])

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

    it "refreshes the TTL on the inflight keys" do
      ::Sidekiq.redis do |redis|
        redis.expire(described_class::INFLIGHT_INDEX_KEY, 10)
        redis.expire(described_class::INFLIGHT_JOBS_KEY, 10)
      end

      registry.update_heartbeats([task.id])

      ::Sidekiq.redis do |redis|
        expect(redis.ttl(described_class::INFLIGHT_INDEX_KEY)).to be > 10
        expect(redis.ttl(described_class::INFLIGHT_JOBS_KEY)).to be > 10
      end
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
      ::Sidekiq.redis do |redis|
        redis.del(described_class::GC_LOCK_KEY)
      end

      expect(registry.acquire_gc_lock).to be true
    end
  end

  describe "#release_gc_lock" do
    it "releases lock held by this process" do
      # Explicitly ensure no lock exists from previous test
      ::Sidekiq.redis do |redis|
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

    it "re-enqueues orphans from a crashed process that is still in the process set" do
      crashed_process_id = "crashed-host:999:deadbeef"
      old_timestamp_ms = ((Time.now.to_f - 400) * 1000).round
      job_payload = {"class" => "TestWorker", "jid" => "crashed-jid", "args" => []}

      add_fake_orphaned_request(
        process_id: crashed_process_id,
        request_id: "orphan-1",
        job_payload: job_payload,
        timestamp_ms: old_timestamp_ms
      )

      # Simulate a crash: the process ID remains in the process set but its
      # max_connections key (refreshed by heartbeats) has expired.
      ::Sidekiq.redis do |redis|
        redis.sadd(described_class::PROCESS_SET_KEY, crashed_process_id)
      end

      expect(Sidekiq::Client).to receive(:push).with(hash_including("jid" => "crashed-jid"))

      count = registry.cleanup_orphaned_requests(300, logger)

      expect(count).to eq(1)
      expect(described_class.inflight_count).to eq(0)
      expect(described_class.registered_process_ids).not_to include(crashed_process_id)
    end

    it "does not re-enqueue orphans belonging to a live process" do
      live_process_id = "live-host:123:cafef00d"
      old_timestamp_ms = ((Time.now.to_f - 400) * 1000).round
      job_payload = {"class" => "TestWorker", "jid" => "live-jid", "args" => []}

      add_fake_orphaned_request(
        process_id: live_process_id,
        request_id: "slow-1",
        job_payload: job_payload,
        timestamp_ms: old_timestamp_ms
      )

      # A live process is in the process set and has an unexpired max_connections key.
      ::Sidekiq.redis do |redis|
        redis.sadd(described_class::PROCESS_SET_KEY, live_process_id)
        redis.set("#{described_class::PROCESS_SET_KEY}:#{live_process_id}:max_connections", 100)
      end

      expect(Sidekiq::Client).not_to receive(:push)

      count = registry.cleanup_orphaned_requests(300, logger)

      expect(count).to eq(0)
      expect(described_class.inflight_count).to eq(1)
      expect(described_class.registered_process_ids).to include(live_process_id)
    end

    it "handles race condition atomically with Lua script" do
      # Register a task
      registry.register(task)

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
      handler2 = PatientHttp::Sidekiq::TaskHandler.new(sidekiq_job.merge("jid" => "test-jid-456"))
      task2 = PatientHttp::RequestTask.new(
        request: request,
        task_handler: handler2,
        callback: TestCallback
      )

      handler3 = PatientHttp::Sidekiq::TaskHandler.new(sidekiq_job.merge("jid" => "test-jid-789"))
      task3 = PatientHttp::RequestTask.new(
        request: request,
        task_handler: handler3,
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
      handler2 = PatientHttp::Sidekiq::TaskHandler.new(sidekiq_job.merge("jid" => "test-jid-456"))
      task2 = PatientHttp::RequestTask.new(
        request: request,
        task_handler: handler2,
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
      ::Sidekiq.redis do |redis|
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
      ::Sidekiq.redis do |redis|
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

      handler2 = PatientHttp::Sidekiq::TaskHandler.new(sidekiq_job.merge("jid" => "test-jid-456"))
      task2 = PatientHttp::RequestTask.new(
        request: request,
        task_handler: handler2,
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
      registry.update_heartbeats([task.id])

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

      handler2 = PatientHttp::Sidekiq::TaskHandler.new(sidekiq_job.merge("jid" => "test-jid-456"))
      task2 = PatientHttp::RequestTask.new(
        request: request,
        task_handler: handler2,
        callback: TestCallback
      )
      registry.register(task2)

      task_ids = registry.registered_task_ids
      expect(task_ids.size).to eq(2)
      expect(task_ids).to include(registry.full_task_id(task.id))
      expect(task_ids).to include(registry.full_task_id(task2.id))
    end

    it "does not include tasks from other registries" do
      registry.register(task)

      other_registry = described_class.new(config)
      other_handler = PatientHttp::Sidekiq::TaskHandler.new(sidekiq_job.merge("jid" => "other-jid"))
      other_task = PatientHttp::RequestTask.new(
        request: request,
        task_handler: other_handler,
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

  describe "batched orphan removal" do
    let(:logger) { instance_double(Logger, info: nil, error: nil) }

    it "removes and re-enqueues many orphans in batches" do
      old_timestamp_ms = ((Time.now.to_f - 400) * 1000).round
      250.times do |i|
        add_fake_orphaned_request(
          process_id: "crashed-host:999:deadbeef",
          request_id: "orphan-#{i}",
          job_payload: {"class" => "TestWorker", "jid" => "jid-#{i}", "args" => []},
          timestamp_ms: old_timestamp_ms
        )
      end

      pushed = []
      allow(Sidekiq::Client).to receive(:push) { |job| pushed << job["jid"] }

      count = registry.cleanup_orphaned_requests(300, logger)

      expect(count).to eq(250)
      expect(pushed.sort).to eq((0...250).map { |i| "jid-#{i}" }.sort)
      expect(described_class.inflight_count).to eq(0)
    end

    it "still works after the server's script cache is flushed" do
      registry.register(task)
      old_timestamp_ms = ((Time.now.to_f - 400) * 1000).round
      set_task_timestamp(registry, task, old_timestamp_ms)

      ::Sidekiq.redis { |redis| redis.call("SCRIPT", "FLUSH") }

      expect(Sidekiq::Client).to receive(:push).with(sidekiq_job)
      count = registry.cleanup_orphaned_requests(300, logger)

      expect(count).to eq(1)
    end
  end

  describe "#release_gc_lock after script cache flush" do
    it "releases the lock with the EVAL fallback" do
      expect(registry.acquire_gc_lock).to be true
      ::Sidekiq.redis { |redis| redis.call("SCRIPT", "FLUSH") }

      expect(registry.release_gc_lock).to be true
    end
  end

  describe "#ping_process with a max_connections callable" do
    it "records the callable's value" do
      counting_registry = described_class.new(config, max_connections: -> { 300 })
      counting_registry.ping_process

      identifier = counting_registry.instance_variable_get(:@lock_identifier)
      value = ::Sidekiq.redis do |redis|
        redis.get("#{described_class::PROCESS_SET_KEY}:#{identifier}:max_connections")
      end
      expect(value).to eq("300")
    end
  end

  describe "#ping_process with a processors callable" do
    let(:snapshot) do
      {default: {inflight: 2, max_capacity: 100}, llm: {inflight: 5, max_capacity: 200}}
    end
    let(:snapshot_registry) { described_class.new(config, processors: -> { snapshot }) }

    it "records the total capacity of all the processors" do
      snapshot_registry.ping_process

      expect(described_class.total_max_connections).to eq(300)
    end

    it "reports the counts of each processor" do
      snapshot_registry.ping_process

      counts = described_class.inflight_counts_by_processor
      expect(counts).to eq(
        "default" => {inflight: 2, max_capacity: 100},
        "llm" => {inflight: 5, max_capacity: 200}
      )
    end

    it "includes the processor counts in the per-process report" do
      snapshot_registry.ping_process

      process = described_class.inflight_counts_by_process.values.first
      expect(process[:processors]).to eq(
        "default" => {inflight: 2, max_capacity: 100},
        "llm" => {inflight: 5, max_capacity: 200}
      )
    end

    it "sums the counts of processes on the same host" do
      snapshot_registry.ping_process
      described_class.new(config, processors: -> { snapshot }).ping_process

      counts = described_class.inflight_counts_by_processor
      expect(counts["llm"]).to eq(inflight: 10, max_capacity: 400)
    end

    it "removes the published counts when the process is removed" do
      snapshot_registry.ping_process
      snapshot_registry.remove_process

      expect(described_class.inflight_counts_by_processor).to eq({})
    end

    it "skips counts it cannot read" do
      snapshot_registry.ping_process
      identifier = snapshot_registry.instance_variable_get(:@lock_identifier)
      ::Sidekiq.redis do |redis|
        redis.set("#{described_class::PROCESS_SET_KEY}:#{identifier}:processors", "not json")
      end

      expect(described_class.inflight_counts_by_processor).to eq({})
    end
  end

  describe ".inflight_counts_by_processor" do
    it "returns an empty hash when no process publishes counts" do
      registry.ping_process

      expect(described_class.inflight_counts_by_processor).to eq({})
    end
  end

  describe "in-flight request details" do
    def register_request(url, processor_name: :default, id: nil)
      handler = PatientHttp::Sidekiq::TaskHandler.new(sidekiq_job.merge("jid" => id || SecureRandom.hex(6)))
      task = PatientHttp::RequestTask.new(
        request: PatientHttp::Request.new(:get, url),
        task_handler: handler,
        callback: TestCallback
      )
      registry.register(task, processor_name: processor_name)
      task
    end

    it "records the URL, method, and processor of each request" do
      register_request("https://api.example.com/v1/things", processor_name: :llm)

      details = described_class.inflight_details

      expect(details.size).to eq(1)
      expect(details.first).to include(
        url: "https://api.example.com/v1/things",
        http_method: "get",
        processor: "llm"
      )
      expect(details.first[:age]).to be >= 0
      expect(details.first[:process_id]).to include(":")
    end

    it "removes the credentials and the query string from the URL" do
      register_request("https://user:secret@api.example.com/things?token=abc#part")

      expect(described_class.inflight_details.first[:url]).to eq("https://api.example.com/things")
    end

    it "applies a configured sanitizer instead of the default one" do
      config.inflight_url_sanitizer { |url| url.sub(%r{/things/\d+}, "/things/:id") }
      register_request("https://api.example.com/things/12345")

      expect(described_class.inflight_details.first[:url]).to eq("https://api.example.com/things/:id")
    end

    it "records nothing when the details are turned off" do
      config.inflight_details = false
      register_request("https://api.example.com/things")

      expect(described_class.inflight_details).to eq([])
    end

    it "still registers the request when the sanitizer raises" do
      config.inflight_url_sanitizer { |_url| raise "boom" }
      task = register_request("https://api.example.com/things")

      expect(registry.registered?(task)).to be(true)
      expect(described_class.inflight_details).to eq([])
    end

    it "truncates a very long URL" do
      register_request("https://api.example.com/#{"a" * 1000}")

      expect(described_class.inflight_details.first[:url].length).to eq(described_class::MAX_DISPLAY_URL_LENGTH)
    end

    it "lists the oldest requests first, up to the limit" do
      register_request("https://api.example.com/first")
      register_request("https://api.example.com/second")
      register_request("https://api.example.com/third")

      urls = described_class.inflight_details.map { |detail| detail[:url] }
      expect(urls).to eq([
        "https://api.example.com/first",
        "https://api.example.com/second",
        "https://api.example.com/third"
      ])
      expect(described_class.inflight_details(limit: 2).size).to eq(2)
      expect(described_class.inflight_details(limit: 0)).to eq([])
    end

    it "stops listing a request when it is unregistered" do
      task = register_request("https://api.example.com/things")
      registry.unregister(task)

      expect(described_class.inflight_details).to eq([])
    end

    it "stops listing a request when the orphan collector re-enqueues it" do
      task = register_request("https://api.example.com/things")
      set_task_timestamp(registry, task, ((Time.now.to_f - 600) * 1000).round)
      expire_process_liveness(registry)
      allow(Sidekiq::Client).to receive(:push)

      registry.cleanup_orphaned_requests(300, config.logger)

      expect(described_class.inflight_details).to eq([])
    end

    it "ignores a record it cannot read" do
      task = register_request("https://api.example.com/things")
      ::Sidekiq.redis do |redis|
        redis.hset(described_class::INFLIGHT_DETAILS_KEY, registry.full_task_id(task.id), "not json")
      end

      expect(described_class.inflight_details).to eq([])
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
