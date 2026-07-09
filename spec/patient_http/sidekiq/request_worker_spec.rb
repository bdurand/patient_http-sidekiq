# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::RequestWorker do
  describe "#perform" do
    let(:sidekiq_job) do
      {
        "class" => "TestWorkers::Worker",
        "jid" => "test-jid",
        "args" => ["arg1", "arg2"]
      }
    end

    let(:config) { PatientHttp::Sidekiq::Configuration.new }
    let(:processor) { PatientHttp::Processor.new(config) }

    around do |example|
      processor.run do
        example.run
      end
    end

    before do
      allow(PatientHttp::Sidekiq).to receive(:processor).and_return(processor)
      allow(PatientHttp::Sidekiq::Context).to receive(:current_job).and_return(sidekiq_job)
    end

    it "processes the request and invokes the callback" do
      template = PatientHttp::RequestTemplate.new(base_url: "http://example.com")
      request = template.get("/test")

      stub_request(:get, "http://example.com/test")
        .to_return(status: 200, body: "OK", headers: {"Content-Type" => "text/plain"})

      Sidekiq::Testing.inline! do
        PatientHttp::Sidekiq::RequestWorker.new.perform(
          request.as_json,
          TestCallback.name,
          false,
          nil,
          SecureRandom.uuid
        )
      end

      # Verify that the callback was invoked
      expect(TestCallback.completion_calls).not_to be_empty
    end

    context "with external storage" do
      let(:stored_ref) do
        request = PatientHttp::RequestTemplate.new(base_url: "http://example.com").get("/test")
        PatientHttp::Sidekiq.external_storage.store(request.as_json)
      end

      before do
        TestPayloadStore.clear!
        PatientHttp::Sidekiq.configure do |c|
          c.register_payload_store(:test_store, adapter: :test_store)
        end
      end

      after { PatientHttp::Sidekiq.reset_configuration! }

      it "keeps the stored payload after submitting the request" do
        allow(PatientHttp::Sidekiq::RequestExecutor).to receive(:execute)

        described_class.new.perform(stored_ref, TestCallback.name, false, nil, SecureRandom.uuid)

        expect(TestPayloadStore.payloads).not_to be_empty
      end

      it "keeps the stored payload when the request cannot be enqueued so Sidekiq retries can fetch it" do
        allow(PatientHttp::Sidekiq::RequestExecutor).to receive(:execute)
          .and_raise(PatientHttp::MaxCapacityError.new("at max capacity"))

        expect {
          described_class.new.perform(stored_ref, TestCallback.name, false, nil, SecureRandom.uuid)
        }.to raise_error(PatientHttp::MaxCapacityError)

        expect(TestPayloadStore.payloads).not_to be_empty
      end
    end

    context "with decryption configured" do
      after { PatientHttp::Sidekiq.reset_configuration! }

      it "decrypts data before loading the request" do
        template = PatientHttp::RequestTemplate.new(base_url: "http://example.com")
        request = template.get("/test")

        # Encrypt the data by wrapping it
        encrypted_data = request.as_json.merge("_encrypted" => true)

        # Configure decryption to remove the marker
        PatientHttp::Sidekiq.configure do |c|
          c.decryption { |data| data.except("_encrypted") }
        end

        stub_request(:get, "http://example.com/test")
          .to_return(status: 200, body: "OK", headers: {"Content-Type" => "text/plain"})

        Sidekiq::Testing.inline! do
          PatientHttp::Sidekiq::RequestWorker.new.perform(
            encrypted_data,
            TestCallback.name,
            false,
            nil,
            SecureRandom.uuid
          )
        end

        expect(TestCallback.completion_calls).not_to be_empty
      end
    end
  end

  describe "sidekiq_retries_exhausted" do
    before do
      TestPayloadStore.clear!
      PatientHttp::Sidekiq.configure do |c|
        c.register_payload_store(:test_store, adapter: :test_store)
      end
    end

    after { PatientHttp::Sidekiq.reset_configuration! }

    it "deletes the stored payload for dead jobs" do
      stored_ref = PatientHttp::Sidekiq.external_storage.store({"http_method" => "get", "url" => "http://example.com/test"})
      dead_job = {"args" => [stored_ref, TestCallback.name, false, nil, "req-1"]}

      described_class.sidekiq_retries_exhausted_block.call(dead_job, RuntimeError.new("exhausted"))

      expect(TestPayloadStore.payloads).to be_empty
    end

    it "does not raise for jobs without stored payloads" do
      dead_job = {"args" => [{"http_method" => "get", "url" => "http://example.com/test"}, TestCallback.name, false, nil, "req-1"]}

      expect {
        described_class.sidekiq_retries_exhausted_block.call(dead_job, RuntimeError.new("exhausted"))
      }.not_to raise_error
    end
  end
end
