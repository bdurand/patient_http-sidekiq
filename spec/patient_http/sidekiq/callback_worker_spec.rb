# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::CallbackWorker do
  describe "#perform" do
    before do
      TestCallback.reset_calls!
    end

    it "invokes on_complete for a successful response" do
      response_data = {
        "status" => 200,
        "headers" => {"Content-Type" => "application/json"},
        "body" => '{"message":"success"}',
        "callback_args" => {}
      }

      expect(PatientHttp::Sidekiq).to receive(:invoke_completion_callbacks).with(an_instance_of(PatientHttp::Response))

      PatientHttp::Sidekiq::CallbackWorker.new.perform(
        response_data,
        "response",
        TestCallback.name
      )

      expect(TestCallback.completion_calls.size).to eq(1)
      expect(TestCallback.completion_calls.first.status).to eq(200)
    end

    context "with decryption configured" do
      after { PatientHttp::Sidekiq.reset_configuration! }

      it "decrypts data before loading the response" do
        response_data = {
          "status" => 200,
          "headers" => {"Content-Type" => "application/json"},
          "body" => '{"message":"success"}',
          "callback_args" => {},
          "_encrypted" => true
        }

        PatientHttp::Sidekiq.configure do |c|
          c.decryption { |data| data.except("_encrypted") }
        end

        expect(PatientHttp::Sidekiq).to receive(:invoke_completion_callbacks).with(an_instance_of(PatientHttp::Response))

        PatientHttp::Sidekiq::CallbackWorker.new.perform(
          response_data,
          "response",
          TestCallback.name
        )

        expect(TestCallback.completion_calls.size).to eq(1)
        expect(TestCallback.completion_calls.first.status).to eq(200)
      end
    end

    it "invokes on_error for an error response" do
      error_data = {
        "message" => "Network error",
        "code" => "network_failure",
        "callback_args" => {}
      }

      expect(PatientHttp::Sidekiq).to receive(:invoke_error_callbacks).with(an_instance_of(PatientHttp::RequestError))

      PatientHttp::Sidekiq::CallbackWorker.new.perform(
        error_data,
        "error",
        TestCallback.name
      )

      expect(TestCallback.error_calls.size).to eq(1)
      expect(TestCallback.error_calls.first.message).to eq("Network error")
    end
  end

  describe "sidekiq_retries_exhausted" do
    let(:error_data) do
      {
        "message" => "Network error",
        "code" => "network_failure",
        "callback_args" => {}
      }
    end

    let(:job) do
      {"args" => [error_data, "error", "TestCallback"]}
    end

    after { PatientHttp::Sidekiq.reset_configuration! }

    it "calls the on_retries_exhausted handler with the error" do
      received_error = nil
      PatientHttp::Sidekiq.configure do |c|
        c.on_retries_exhausted = ->(error) { received_error = error }
      end

      described_class.sidekiq_retries_exhausted_block.call(job, RuntimeError.new("exhausted"))

      expect(received_error).to be_a(PatientHttp::RequestError)
      expect(received_error.message).to eq("Network error")
    end

    it "does not raise if no handler is configured" do
      PatientHttp::Sidekiq.configure { |c| }

      expect {
        described_class.sidekiq_retries_exhausted_block.call(job, RuntimeError.new("exhausted"))
      }.not_to raise_error
    end

    it "does not call the handler for response result_type" do
      called = false
      PatientHttp::Sidekiq.configure do |c|
        c.on_retries_exhausted { |_error| called = true }
      end

      response_job = {"args" => [error_data, "response", "TestCallback"]}
      described_class.sidekiq_retries_exhausted_block.call(response_job, RuntimeError.new("exhausted"))

      expect(called).to be false
    end

    it "logs a warning if the handler raises" do
      PatientHttp::Sidekiq.configure do |c|
        c.on_retries_exhausted = ->(_error) { raise "handler error" }
      end

      allow(PatientHttp::ExternalStorage).to receive(:delete)

      expect(PatientHttp::Sidekiq.configuration.logger).to receive(:warn).with(
        /on_retries_exhausted handler failed/
      )

      described_class.sidekiq_retries_exhausted_block.call(job, RuntimeError.new("exhausted"))
    end
  end
end
