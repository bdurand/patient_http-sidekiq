# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::DirectTaskHandler do
  let(:args) { [{"http_method" => "get", "url" => "http://example.com/test"}, "TestCallback", false, nil, "req-1"] }

  describe "#sidekiq_job" do
    it "returns a minimal job record for the crash-recovery registry" do
      handler = described_class.new(args)

      job = handler.sidekiq_job
      expect(job["class"]).to eq("PatientHttp::Sidekiq::RequestWorker")
      expect(job["args"]).to eq(args)
      expect(job["queue"]).to eq("default")
      expect(job["retry"]).to eq(true)
      expect(job).not_to have_key("jid")
      expect(job).not_to have_key("created_at")
    end

    it "includes the scoped Sidekiq options" do
      handler = described_class.new(args, {
        "queue" => "high_priority",
        "retry" => 3,
        "patient_http_callback_queue" => "high_priority"
      })

      job = handler.sidekiq_job
      expect(job["queue"]).to eq("high_priority")
      expect(job["retry"]).to eq(3)
      expect(job["patient_http_callback_queue"]).to eq("high_priority")
    end

    it "serializes to JSON for the crash-recovery registry" do
      handler = described_class.new(args)

      job = JSON.parse(JSON.generate(handler.sidekiq_job))
      expect(job["class"]).to eq("PatientHttp::Sidekiq::RequestWorker")
      expect(job["args"]).to eq(args)
    end
  end

  describe "#retry" do
    it "enqueues a RequestWorker job with the original arguments" do
      handler = described_class.new(args)

      handler.retry

      job = PatientHttp::Sidekiq::RequestWorker.jobs.first
      expect(job["args"]).to eq(args)
      expect(job["queue"]).to eq("default")
    end

    it "applies the scoped Sidekiq options to the job" do
      handler = described_class.new(args, {
        "queue" => "high_priority",
        "retry" => 3,
        "patient_http_callback_queue" => "high_priority"
      })

      handler.retry

      job = PatientHttp::Sidekiq::RequestWorker.jobs.first
      expect(job["args"]).to eq(args)
      expect(job["queue"]).to eq("high_priority")
      expect(job["retry"]).to eq(3)
      expect(job["patient_http_callback_queue"]).to eq("high_priority")
    end
  end

  describe "#job_id" do
    it "returns nil because no Sidekiq job exists" do
      handler = described_class.new(args)

      expect(handler.job_id).to be_nil
    end
  end

  describe "#on_complete" do
    before { TestCallback.reset_calls! }

    it "routes the callback job to the callback queue from the options" do
      handler = described_class.new(args, {
        "queue" => "high_priority",
        "patient_http_callback_queue" => "high_priority"
      })

      response = PatientHttp::Response.new(
        status: 200,
        headers: {"Content-Type" => "text/plain"},
        body: "OK",
        duration: 0.1,
        request_id: "req-1",
        url: "http://example.com/test",
        http_method: "get"
      )
      handler.on_complete(response, TestCallback.name)

      job = PatientHttp::Sidekiq::CallbackWorker.jobs.last
      expect(job["queue"]).to eq("high_priority")
    end

    context "with external payload storage" do
      before do
        TestPayloadStore.clear!
        PatientHttp::Sidekiq.configure do |c|
          c.register_payload_store(:test_store, adapter: :test_store)
        end
      end

      after { PatientHttp::Sidekiq.reset_configuration! }

      it "deletes the stored request payload" do
        stored_ref = PatientHttp::Sidekiq.external_storage.store(args.first, max_size: 1)
        handler = described_class.new([stored_ref, *args[1..]])
        expect(TestPayloadStore.payloads).not_to be_empty

        response = PatientHttp::Response.new(
          status: 200,
          headers: {"Content-Type" => "text/plain"},
          body: "OK",
          duration: 0.1,
          request_id: "req-1",
          url: "http://example.com/test",
          http_method: "get"
        )
        handler.on_complete(response, TestCallback.name)

        expect(TestPayloadStore.payloads).to be_empty
      end
    end
  end
end
