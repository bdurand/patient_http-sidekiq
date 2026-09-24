# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Named processors" do
  after do
    PatientHttp::Sidekiq.reset!
    PatientHttp::Sidekiq.reset_configuration!
  end

  describe "lifecycle" do
    before do
      PatientHttp::Sidekiq.configure do |config|
        config.max_connections = 50
        config.processor(:llm, max_connections: 20, request_timeout: 120)
        config.processor(:webhooks, max_connections: 10, request_timeout: 10)
      end
    end

    it "starts one processor per profile with its own configuration" do
      PatientHttp::Sidekiq.start

      default_processor = PatientHttp::Sidekiq.processor
      llm_processor = PatientHttp::Sidekiq.processor(:llm)
      webhook_processor = PatientHttp::Sidekiq.processor(:webhooks)

      expect(default_processor).to be_running
      expect(llm_processor).to be_running
      expect(webhook_processor).to be_running

      expect(default_processor.config.max_connections).to eq(50)
      expect(llm_processor.config.max_connections).to eq(20)
      expect(llm_processor.config.request_timeout).to eq(120)
      expect(webhook_processor.config.max_connections).to eq(10)
      expect(llm_processor.name).to eq("llm")
    end

    it "drains and stops all processors" do
      PatientHttp::Sidekiq.start
      processors = [:default, :llm, :webhooks].map { |name| PatientHttp::Sidekiq.processor(name) }

      PatientHttp::Sidekiq.quiet
      expect(processors).to all(be_draining)

      PatientHttp::Sidekiq.stop
      expect(processors).to all(be_stopped)
      expect(PatientHttp::Sidekiq.processor).to be_nil
    end

    it "stops the other processors when one of them fails to stop" do
      PatientHttp::Sidekiq.start
      llm_processor = PatientHttp::Sidekiq.processor(:llm)
      other_processors = [:default, :webhooks].map { |name| PatientHttp::Sidekiq.processor(name) }
      allow(llm_processor).to receive(:stop).and_wrap_original do |original, **options|
        original.call(**options)
        raise "boom"
      end

      expect { PatientHttp::Sidekiq.stop(timeout: 0) }.not_to raise_error

      expect(other_processors).to all(be_stopped)
      expect(PatientHttp::Sidekiq.redis_pool).to be_nil
    end

    it "reports the summed max connections through the process registry" do
      PatientHttp::Sidekiq.start

      counts = PatientHttp::Sidekiq::TaskMonitor.inflight_counts_by_process
      expect(counts.values.sum { |data| data[:max_capacity] }).to eq(80)
    end
  end

  describe ".processor_config_for" do
    before do
      PatientHttp::Sidekiq.configure do |config|
        config.processor(:llm, max_connections: 20)
      end
    end

    it "returns the running processor's configuration" do
      PatientHttp::Sidekiq.start

      expect(PatientHttp::Sidekiq.processor_config_for(:llm)).to be(PatientHttp::Sidekiq.processor(:llm).config)
    end

    it "returns the declared profile configuration when no processor is running" do
      config = PatientHttp::Sidekiq.processor_config_for("llm")

      expect(config).to be(PatientHttp::Sidekiq.configuration.processor_config(:llm))
      expect(config.max_connections).to eq(20)
    end

    it "returns the base configuration for a name without a declared profile" do
      expect(PatientHttp::Sidekiq.processor_config_for(:undeclared)).to be(PatientHttp::Sidekiq.configuration)
    end
  end

  describe "routing" do
    before do
      PatientHttp::Sidekiq.configure do |config|
        config.processor(:llm, max_connections: 20)
      end
    end

    it "serializes the processor name into the RequestWorker job args" do
      request = PatientHttp::Request.new(:get, "https://example.com")
      PatientHttp::Sidekiq.execute(request, callback: TestCallback, processor: :llm)

      job = PatientHttp::Sidekiq::RequestWorker.jobs.last
      expect(job["args"].last).to eq("llm")
    end

    it "uses the request's own processor name when no explicit option is given" do
      request = PatientHttp::Request.new(:get, "https://example.com", processor: :llm)
      PatientHttp::Sidekiq.execute(request, callback: TestCallback)

      job = PatientHttp::Sidekiq::RequestWorker.jobs.last
      expect(job["args"].last).to eq("llm")
    end

    it "accepts a processor from with_sidekiq_options and strips it from the job options" do
      request = PatientHttp::Request.new(:get, "https://example.com")
      PatientHttp::Sidekiq.with_sidekiq_options("processor" => "llm", "queue" => "critical") do
        PatientHttp::Sidekiq.execute(request, callback: TestCallback)
      end

      job = PatientHttp::Sidekiq::RequestWorker.jobs.last
      expect(job["args"].last).to eq("llm")
      expect(job["queue"]).to eq("critical")
      expect(job).not_to have_key("processor")
    end

    it "defaults to the default processor" do
      request = PatientHttp::Request.new(:get, "https://example.com")
      PatientHttp::Sidekiq.execute(request, callback: TestCallback)

      job = PatientHttp::Sidekiq::RequestWorker.jobs.last
      expect(job["args"].last).to eq("default")
    end

    it "uses the processor profile raise_error_responses when none is given" do
      PatientHttp::Sidekiq.configure { |config| config.processor(:strict, raise_error_responses: true) }

      request = PatientHttp::Request.new(:get, "https://example.com")
      PatientHttp::Sidekiq.execute(request, callback: TestCallback, processor: :strict)

      job = PatientHttp::Sidekiq::RequestWorker.jobs.last
      expect(job["args"][2]).to be(true)
      expect(PatientHttp::Sidekiq.configuration.processor(:strict)).to eq(raise_error_responses: true)
    end

    it "uses the base raise_error_responses for a profile that does not override it" do
      PatientHttp::Sidekiq.configuration.raise_error_responses = true

      request = PatientHttp::Request.new(:get, "https://example.com")
      PatientHttp::Sidekiq.execute(request, callback: TestCallback, processor: :llm)

      job = PatientHttp::Sidekiq::RequestWorker.jobs.last
      expect(job["args"][2]).to be(true)
    end

    it "raises for a processor profile that is not declared" do
      request = PatientHttp::Request.new(:get, "https://example.com")

      expect do
        PatientHttp::Sidekiq.execute(request, callback: TestCallback, processor: :undeclared)
      end.to raise_error(PatientHttp::UnknownProcessorError, /undeclared/)
      expect(PatientHttp::Sidekiq::RequestWorker.jobs).to be_empty
    end

    it "raises for an undeclared processor set on the request or in with_sidekiq_options" do
      request = PatientHttp::Request.new(:get, "https://example.com", processor: :on_request)
      expect do
        PatientHttp::Sidekiq.execute(request, callback: TestCallback)
      end.to raise_error(PatientHttp::UnknownProcessorError, /on_request/)

      request = PatientHttp::Request.new(:get, "https://example.com")
      expect do
        PatientHttp::Sidekiq.with_sidekiq_options("processor" => "in_block") do
          PatientHttp::Sidekiq.execute(request, callback: TestCallback)
        end
      end.to raise_error(PatientHttp::UnknownProcessorError, /in_block/)

      expect(PatientHttp::Sidekiq::RequestWorker.jobs).to be_empty
    end

    it "uses the processor profile payload_store_threshold" do
      TestPayloadStore.clear!
      PatientHttp::Sidekiq.configure do |config|
        config.register_payload_store(:test_store, adapter: :test_store)
        config.processor(:small, payload_store_threshold: 1)
      end

      request = PatientHttp::Request.new(:get, "https://example.com")
      PatientHttp::Sidekiq.execute(request, callback: TestCallback)
      default_data = PatientHttp::Sidekiq::RequestWorker.jobs.last["args"][0]

      PatientHttp::Sidekiq.execute(request, callback: TestCallback, processor: :small)
      small_data = PatientHttp::Sidekiq::RequestWorker.jobs.last["args"][0]

      expect(PatientHttp::ExternalStorage.storage_ref?(default_data)).to be(false)
      expect(PatientHttp::ExternalStorage.storage_ref?(small_data)).to be(true)
    end
  end

  describe "execution on a named processor" do
    it "enqueues the task on the processor named in the job" do
      PatientHttp::Sidekiq.configure do |config|
        config.processor(:llm, max_connections: 20)
      end
      PatientHttp::Sidekiq.start

      captured = nil
      allow(PatientHttp::Sidekiq.processor(:llm)).to receive(:enqueue) { |task| captured = task }

      request = PatientHttp::Request.new(:get, "https://example.com")
      PatientHttp::Sidekiq::RequestExecutor.execute(
        request,
        callback: TestCallback,
        sidekiq_job: {"class" => "TestWorker", "args" => []},
        processor_name: "llm"
      )

      expect(captured).to be_a(PatientHttp::RequestTask)
    end

    it "builds the task handler with the named processor configuration" do
      PatientHttp::Sidekiq.configure do |config|
        config.processor(:llm, max_connections: 20)
      end
      PatientHttp::Sidekiq.start

      allow(PatientHttp::Sidekiq.processor(:llm)).to receive(:enqueue)
      expect(PatientHttp::Sidekiq::TaskHandler).to receive(:new)
        .with(anything, config: PatientHttp::Sidekiq.processor(:llm).config)
        .and_call_original

      request = PatientHttp::Request.new(:get, "https://example.com")
      PatientHttp::Sidekiq::RequestExecutor.execute(
        request,
        callback: TestCallback,
        sidekiq_job: {"class" => "TestWorker", "args" => []},
        processor_name: "llm"
      )
    end

    it "raises UnknownProcessorError for a job naming an unconfigured processor" do
      PatientHttp::Sidekiq.start

      request = PatientHttp::Request.new(:get, "https://example.com")
      expect do
        PatientHttp::Sidekiq::RequestExecutor.execute(
          request,
          callback: TestCallback,
          sidekiq_job: {"class" => "TestWorker", "args" => []},
          processor_name: "nope"
        )
      end.to raise_error(PatientHttp::UnknownProcessorError, /nope/)
    end
  end

  describe "capacity fast path" do
    it "rejects without touching the crash-recovery registry when the processor is full" do
      PatientHttp::Sidekiq.configure do |config|
        config.max_connections = 1
      end
      PatientHttp::Sidekiq.start
      processor = PatientHttp::Sidekiq.processor
      allow(processor).to receive(:capacity_available?).and_return(false)

      request = PatientHttp::Request.new(:get, "https://example.com")
      expect do
        PatientHttp::Sidekiq::RequestExecutor.execute(
          request,
          callback: TestCallback,
          sidekiq_job: {"class" => "TestWorker", "args" => []}
        )
      end.to raise_error(PatientHttp::MaxCapacityError)

      # The rejection never registered anything, so the registry stays empty.
      expect(PatientHttp::Sidekiq::TaskMonitor.inflight_count).to eq(0)

      # The rejection was still counted.
      totals = PatientHttp::Sidekiq.stats.get_totals
      expect(totals["max_capacity_exceeded"]).to eq(1)
    end
  end
end
