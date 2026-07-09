# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::TaskHandler do
  let(:sidekiq_job) do
    {
      "class" => "TestWorker",
      "jid" => "test-jid-123",
      "args" => [1, 2, 3]
    }
  end

  let(:handler) { described_class.new(sidekiq_job) }

  describe "#on_complete" do
    before { TestCallback.reset_calls! }
    after { PatientHttp::Sidekiq.reset_configuration! }

    it "encrypts the response data before enqueuing" do
      PatientHttp::Sidekiq.configure do |c|
        c.encryption { |bytes| [bytes].pack("m0") }
        c.decryption { |bytes| bytes.unpack1("m0") }
      end

      response = PatientHttp::Response.new(
        status: 200,
        headers: {"Content-Type" => "text/plain"},
        body: "OK",
        duration: 0.1,
        request_id: "req-123",
        url: "http://example.com/test",
        http_method: "get"
      )

      handler = described_class.new(sidekiq_job)
      handler.on_complete(response, TestCallback.name)

      job = PatientHttp::Sidekiq::CallbackWorker.jobs.last
      data = job["args"][0]

      expect(data["__encrypted__"]).to eq(true)
      expect(data["value"]).to be_a(String)
    end
  end

  describe "#retry" do
    it "re-enqueues the original Sidekiq job" do
      expect(Sidekiq::Client).to receive(:push).with(sidekiq_job).and_return("new-jid")
      result = handler.retry
      expect(result).to eq("new-jid")
    end

    it "preserves all job attributes" do
      job_with_metadata = sidekiq_job.merge("retry_count" => 2, "custom_field" => "value")
      handler_with_metadata = described_class.new(job_with_metadata)
      expect(Sidekiq::Client).to receive(:push) do |job|
        expect(job["retry_count"]).to eq(2)
        expect(job["custom_field"]).to eq("value")
        "new-jid"
      end
      handler_with_metadata.retry
    end
  end

  describe "#on_error" do
    before { TestCallback.reset_calls! }
    after { PatientHttp::Sidekiq.reset_configuration! }

    it "encrypts the error data before enqueuing" do
      PatientHttp::Sidekiq.configure do |c|
        c.encryption { |bytes| bytes }
        c.decryption { |bytes| bytes }
      end

      error = PatientHttp::RequestError.new(
        class_name: "StandardError",
        message: "test error",
        backtrace: ["line 1"],
        error_type: "runtime",
        duration: 0.1,
        request_id: "req-456",
        url: "http://example.com/test",
        http_method: "get"
      )

      handler = described_class.new(sidekiq_job)
      handler.on_error(error, TestCallback.name)

      job = PatientHttp::Sidekiq::CallbackWorker.jobs.last
      data = job["args"][0]

      expect(data["__encrypted__"]).to eq(true)
      expect(data["value"]).to be_a(String)
    end
  end

  describe "stored request payload cleanup" do
    let(:response) do
      PatientHttp::Response.new(
        status: 200,
        headers: {"Content-Type" => "text/plain"},
        body: "OK",
        duration: 0.1,
        request_id: "req-123",
        url: "http://example.com/test",
        http_method: "get"
      )
    end

    let(:error) do
      PatientHttp::RequestError.new(
        class_name: "StandardError",
        message: "test error",
        backtrace: ["line 1"],
        error_type: "runtime",
        duration: 0.1,
        request_id: "req-456",
        url: "http://example.com/test",
        http_method: "get"
      )
    end

    before do
      TestPayloadStore.clear!
      PatientHttp::Sidekiq.configure do |c|
        c.register_payload_store(:test_store, adapter: :test_store)
      end
    end

    after { PatientHttp::Sidekiq.reset_configuration! }

    def request_worker_job_with_stored_payload
      stored_ref = PatientHttp::Sidekiq.external_storage.store(
        {"http_method" => "get", "url" => "http://example.com/test"}
      )
      {
        "class" => PatientHttp::Sidekiq::RequestWorker.name,
        "jid" => "request-jid",
        "args" => [stored_ref, TestCallback.name, false, nil, "req-1"]
      }
    end

    it "deletes the stored request payload when the request completes" do
      handler = described_class.new(request_worker_job_with_stored_payload)
      handler.on_complete(response, TestCallback.name)

      expect(TestPayloadStore.payloads).to be_empty
    end

    it "deletes the stored request payload when the request errors" do
      handler = described_class.new(request_worker_job_with_stored_payload)
      handler.on_error(error, TestCallback.name)

      expect(TestPayloadStore.payloads).to be_empty
    end

    it "does not delete the stored request payload when the job is retried" do
      handler = described_class.new(request_worker_job_with_stored_payload)
      allow(Sidekiq::Client).to receive(:push)
      handler.retry

      expect(TestPayloadStore.payloads).not_to be_empty
    end

    it "does not delete arguments of other job classes" do
      stored_ref = PatientHttp::Sidekiq.external_storage.store({"some" => "data"})
      handler = described_class.new(
        "class" => "TestWorker",
        "jid" => "other-jid",
        "args" => [stored_ref]
      )
      handler.on_complete(response, TestCallback.name)

      expect(TestPayloadStore.payloads).not_to be_empty
    end
  end
end
