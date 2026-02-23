# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::RequestWorker do
  describe ".perform" do
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
end
