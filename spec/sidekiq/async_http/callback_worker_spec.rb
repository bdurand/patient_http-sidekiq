# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::CallbackWorker do
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

      expect(Sidekiq::AsyncHttp).to receive(:invoke_completion_callbacks).with(an_instance_of(Sidekiq::AsyncHttp::Response))

      Sidekiq::AsyncHttp::CallbackWorker.new.perform(
        response_data,
        "response",
        TestCallback.name
      )

      expect(TestCallback.completion_calls.size).to eq(1)
      expect(TestCallback.completion_calls.first.status).to eq(200)
    end

    context "with decryption configured" do
      after { Sidekiq::AsyncHttp.reset_configuration! }

      it "decrypts data before loading the response" do
        response_data = {
          "status" => 200,
          "headers" => {"Content-Type" => "application/json"},
          "body" => '{"message":"success"}',
          "callback_args" => {},
          "_encrypted" => true
        }

        Sidekiq::AsyncHttp.configure do |c|
          c.decryption { |data| data.except("_encrypted") }
        end

        expect(Sidekiq::AsyncHttp).to receive(:invoke_completion_callbacks).with(an_instance_of(Sidekiq::AsyncHttp::Response))

        Sidekiq::AsyncHttp::CallbackWorker.new.perform(
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

      expect(Sidekiq::AsyncHttp).to receive(:invoke_error_callbacks).with(an_instance_of(Sidekiq::AsyncHttp::RequestError))

      Sidekiq::AsyncHttp::CallbackWorker.new.perform(
        error_data,
        "error",
        TestCallback.name
      )

      expect(TestCallback.error_calls.size).to eq(1)
      expect(TestCallback.error_calls.first.message).to eq("Network error")
    end
  end
end
