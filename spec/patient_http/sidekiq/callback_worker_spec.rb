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

    context "with external storage" do
      let(:response_data) do
        {
          "status" => 200,
          "headers" => {"Content-Type" => "application/json"},
          "body" => '{"message":"success"}',
          "callback_args" => {}
        }
      end

      before do
        TestPayloadStore.clear!
        PatientHttp::Sidekiq.configure do |c|
          c.register_payload_store(:test_store, adapter: :test_store)
        end
      end

      after { PatientHttp::Sidekiq.reset_configuration! }

      it "deletes the stored payload after the callback succeeds" do
        stored_ref = PatientHttp::Sidekiq.external_storage.store(response_data)

        PatientHttp::Sidekiq::CallbackWorker.new.perform(
          stored_ref,
          "response",
          TestCallback.name
        )

        expect(TestCallback.completion_calls.size).to eq(1)
        expect(TestPayloadStore.payloads).to be_empty
      end

      it "keeps the stored payload when the callback raises so retries can fetch it" do
        failing_callback = Class.new do
          def on_complete(response)
            raise "callback failed"
          end

          def on_error(error)
            raise "callback failed"
          end
        end
        stub_const("FailingCallback", failing_callback)

        stored_ref = PatientHttp::Sidekiq.external_storage.store(response_data)

        expect {
          PatientHttp::Sidekiq::CallbackWorker.new.perform(
            stored_ref,
            "response",
            "FailingCallback"
          )
        }.to raise_error("callback failed")

        expect(TestPayloadStore.payloads).not_to be_empty
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

      expect(PatientHttp::Sidekiq.configuration.logger).to receive(:warn).with(
        /on_retries_exhausted handler failed/
      )

      described_class.sidekiq_retries_exhausted_block.call(job, RuntimeError.new("exhausted"))
    end

    it "deletes the stored payload for dead jobs" do
      TestPayloadStore.clear!
      PatientHttp::Sidekiq.configure do |c|
        c.register_payload_store(:test_store, adapter: :test_store)
      end

      stored_ref = PatientHttp::Sidekiq.external_storage.store(error_data)
      dead_job = {"args" => [stored_ref, "error", "TestCallback"]}

      described_class.sidekiq_retries_exhausted_block.call(dead_job, RuntimeError.new("exhausted"))

      expect(TestPayloadStore.payloads).to be_empty
    end
  end
end
