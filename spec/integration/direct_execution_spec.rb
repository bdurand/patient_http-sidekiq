# frozen_string_literal: true

require "spec_helper"
require "support/test_web_server"

RSpec.describe "Direct Execution", :integration do
  let(:config) { PatientHttp::Sidekiq::Configuration.new(max_connections: 5) }
  let(:processor) { PatientHttp::Processor.new(config) }

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
