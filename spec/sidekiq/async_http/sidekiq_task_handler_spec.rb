# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::SidekiqTaskHandler do
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
    after { Sidekiq::AsyncHttp.reset_configuration! }

    it "encrypts the response data before enqueuing" do
      Sidekiq::AsyncHttp.configure do |c|
        c.encryption { |data| data.merge("_encrypted" => true) }
      end

      response = Sidekiq::AsyncHttp::Response.new(
        status: 200,
        headers: {"Content-Type" => "text/plain"},
        body: "OK",
        duration: 0.1,
        request_id: "req-123",
        url: "http://example.com/test",
        http_method: "get"
      )

      handler.on_complete(response, TestCallback.name)

      job = Sidekiq::AsyncHttp::CallbackWorker.jobs.last
      data = job["args"][0]

      expect(data["_encrypted"]).to eq(true)
      expect(data["status"]).to eq(200)
    end
  end

  describe "#on_error" do
    before { TestCallback.reset_calls! }
    after { Sidekiq::AsyncHttp.reset_configuration! }

    it "encrypts the error data before enqueuing" do
      Sidekiq::AsyncHttp.configure do |c|
        c.encryption { |data| data.merge("_encrypted" => true) }
      end

      error = Sidekiq::AsyncHttp::RequestError.new(
        class_name: "StandardError",
        message: "test error",
        backtrace: ["line 1"],
        error_type: "runtime",
        duration: 0.1,
        request_id: "req-456",
        url: "http://example.com/test",
        http_method: "get"
      )

      handler.on_error(error, TestCallback.name)

      job = Sidekiq::AsyncHttp::CallbackWorker.jobs.last
      data = job["args"][0]

      expect(data["_encrypted"]).to eq(true)
      expect(data["message"]).to eq("test error")
    end
  end
end
