# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::RequestWorker do
  describe ".perform" do
    let(:sidekiq_job) do
      {
        "class" => "TestWorkers::Worker",
        "jid" => "test-jid",
        "args" => ["arg1", "arg2"]
      }
    end

    let(:config) { Sidekiq::AsyncHttp::Configuration.new }
    let(:processor) { Sidekiq::AsyncHttp::Processor.new(config) }

    around do |example|
      processor.run do
        example.run
      end
    end

    before do
      allow(Sidekiq::AsyncHttp).to receive(:processor).and_return(processor)
      allow(Sidekiq::AsyncHttp::Context).to receive(:current_job).and_return(sidekiq_job)
    end

    it "processes the request and invokes the callback" do
      client = Sidekiq::AsyncHttp::Client.new(base_url: "http://example.com")
      request = client.async_get("/test")

      stub_request(:get, "http://example.com/test")
        .to_return(status: 200, body: "OK", headers: {"Content-Type" => "text/plain"})

      Sidekiq::Testing.inline! do
        Sidekiq::AsyncHttp::RequestWorker.new.perform(
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
  end
end
