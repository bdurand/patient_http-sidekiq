# frozen_string_literal: true

require "spec_helper"
require "support/test_web_server"

RSpec.describe "Direct Execution", :integration do
  let(:config) { PatientHttp::Sidekiq::Configuration.new(max_connections: 5) }
  let(:processor) { PatientHttp::Processor.new(config) }

  def build_observer
    PatientHttp::Sidekiq::ProcessorObserver.new(
      processor,
      stats: PatientHttp::Sidekiq::Stats.new(config),
      task_monitor: PatientHttp::Sidekiq::TaskMonitor.new(config)
    )
  end

  around do |example|
    # The testing mode must be changed globally, not with the thread-local
    # block form, so the processor's reactor thread also enqueues callback
    # jobs to the real Redis queue.
    original_testing_mode = Sidekiq::Testing.instance_variable_get(:@test_mode) || :fake
    Sidekiq::Testing.disable!
    begin
      processor.run do
        example.run
      end
    ensure
      if original_testing_mode == :inline
        Sidekiq::Testing.inline!
      elsif original_testing_mode == :disable
        Sidekiq::Testing.disable!
      else
        Sidekiq::Testing.fake!
      end
    end
  end

  before do
    TestCallback.reset_calls!
    PatientHttp::Sidekiq.processor = processor
  end

  after do
    PatientHttp::Sidekiq.processor = nil
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      return true if yield

      sleep(0.05)
    end
    false
  end

  def enqueued_jobs(queue = "default")
    payloads = ::Sidekiq.redis { |redis| redis.lrange("queue:#{queue}", 0, -1) }
    payloads.map { |json| JSON.parse(json) }
  end

  it "executes the request on the local processor and enqueues only the callback job" do
    request = PatientHttp::Request.new(:get, "#{test_web_server.base_url}/test/200")

    request_id = PatientHttp::Sidekiq.execute(request, callback: TestCallback)

    expect(wait_until { enqueued_jobs.size == 1 }).to be(true)

    job = enqueued_jobs.first
    expect(job["class"]).to eq("PatientHttp::Sidekiq::CallbackWorker")

    PatientHttp::Sidekiq::CallbackWorker.new.perform(*job["args"])

    expect(TestCallback.completion_calls.size).to eq(1)
    response = TestCallback.completion_calls.first
    expect(response.status).to eq(200)
    expect(response.request_id).to eq(request_id)
  end

  it "raises when the crash-recovery registry entry cannot be written" do
    observer = build_observer
    processor.observe(observer)
    allow(observer.task_monitor).to receive(:register).and_raise("Redis is unavailable")
    # Prove the error propagates on the production path, not through the
    # testing-mode re-raise in the processor's observer notifications.
    allow(PatientHttp).to receive(:testing?).and_return(false)

    request = PatientHttp::Request.new(:get, "#{test_web_server.base_url}/test/200")

    expect do
      PatientHttp::Sidekiq.execute(request, callback: TestCallback)
    end.to raise_error(RuntimeError, "Redis is unavailable")

    # The processor did not accept the task, so nothing executes without a
    # durable record.
    expect(processor.tracked_request_ids).to be_empty
    expect(enqueued_jobs).to be_empty
  end

  it "records the highest number of requests the processor held at once" do
    # Per-processor statistics are only recorded when more than one profile
    # exists; the requests still run on the default processor.
    config.processor(:llm, max_connections: 5)
    stats = PatientHttp::Sidekiq::Stats.new(config)
    processor.observe(
      PatientHttp::Sidekiq::ProcessorObserver.new(
        processor,
        stats: stats,
        task_monitor: PatientHttp::Sidekiq::TaskMonitor.new(config)
      )
    )

    3.times do
      PatientHttp::Sidekiq.execute(
        PatientHttp::Request.new(:get, "#{test_web_server.base_url}/delay/500"),
        callback: TestCallback
      )
    end

    # The mark is published even though nothing has completed yet.
    expect(stats.get_totals["processors"]["default"]["max_inflight"]).to eq(3)

    expect(wait_until { processor.total_count.zero? }).to be(true)
    expect(stats.get_totals["processors"]["default"]["max_inflight"]).to eq(3)
  end

  it "registers the request in the crash-recovery registry before execute returns" do
    observer = build_observer
    processor.observe(observer)

    request = PatientHttp::Request.new(:get, "#{test_web_server.base_url}/delay/500")
    request_id = PatientHttp::Sidekiq.execute(request, callback: TestCallback)

    registered_ids = observer.task_monitor.registered_task_ids
    expect(registered_ids).to include(a_string_ending_with("/#{request_id}"))

    # The entry is removed when the request completes.
    expect(wait_until { observer.task_monitor.registered_task_ids.empty? }).to be(true)
  end

  context "with external payload storage" do
    before do
      TestPayloadStore.clear!
      PatientHttp::Sidekiq.configure do |c|
        c.register_payload_store(:test_store, adapter: :test_store)
        c.payload_store_threshold = 1
      end
    end

    after do
      PatientHttp::Sidekiq.reset_configuration!
    end

    it "deletes the stored request payload after the request completes" do
      request = PatientHttp::Request.new(:get, "#{test_web_server.base_url}/test/200")

      PatientHttp::Sidekiq.execute(request, callback: TestCallback)
      request_payload_key = TestPayloadStore.payloads.keys.first

      # The request payload is deleted on completion; only the response payload
      # stored for the callback job remains.
      expect(wait_until { enqueued_jobs.size == 1 }).to be(true)
      expect(wait_until { !TestPayloadStore.payloads.key?(request_payload_key) }).to be(true)
      expect(wait_until { TestPayloadStore.payloads.size == 1 }).to be(true)

      job = enqueued_jobs.first
      expect(job["class"]).to eq("PatientHttp::Sidekiq::CallbackWorker")
    end
  end
end
