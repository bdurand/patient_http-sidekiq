# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Error Handling Integration", :integration do
  include Async::RSpec::Reactor

  let(:config) do
    Sidekiq::AsyncHttp::Configuration.new.tap do |c|
      c.max_connections = 10
      c.request_timeout = 5
    end
  end

  let(:processor) { Sidekiq::AsyncHttp::Processor.new(config) }

  around do |example|
    TestWorkers::Worker.reset_calls!
    TestWorkers::CompletionWorker.reset_calls!
    TestWorkers::ErrorWorker.reset_calls!

    # Disable WebMock completely for integration tests
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!

    processor.run do
      example.run
    end
  ensure
    # Re-enable WebMock
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  describe "timeout errors" do
    it "calls error worker with timeout error when request exceeds timeout" do
      # Make request with short timeout (use a longer delay to ensure timeout)
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url, timeout: 0.1)
      request = client.async_get("/delay/5000")

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "timeout-test", "args" => []},
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker",
        callback_args: {"arg" => "timeout_arg"}
      )

      processor.enqueue(request_task)
      processor.wait_for_idle

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # Verify error worker was called
      expect(TestWorkers::ErrorWorker.calls.size).to eq(1)
      expect(TestWorkers::CompletionWorker.calls.size).to eq(0)

      error = TestWorkers::ErrorWorker.calls.first.first
      expect(error).to be_a(Sidekiq::AsyncHttp::Error)
      expect(error.error_type).to eq(:timeout)
      expect(error.error_class.name).to match(/Timeout/)
      expect(error.callback_args[:arg]).to eq("timeout_arg")
    end
  end

  describe "connection errors" do
    it "calls error worker with connection error when server is not listening" do
      # Make request to a port that's not listening
      client = Sidekiq::AsyncHttp::Client.new(base_url: "http://127.0.0.1:1")
      request = client.async_get("/nowhere")

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "conn-test", "args" => []},
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker",
        callback_args: {"arg" => "connection_arg"}
      )

      processor.enqueue(request_task)
      processor.wait_for_idle

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # Verify error worker was called
      expect(TestWorkers::ErrorWorker.calls.size).to eq(1)
      expect(TestWorkers::CompletionWorker.calls.size).to eq(0)

      error = TestWorkers::ErrorWorker.calls.first.first
      expect(error).to be_a(Sidekiq::AsyncHttp::Error)
      expect(error.error_type).to eq(:connection)
      expect(error.error_class.name).to match(/Errno::E/)
      expect(error.message).to match(/refused|reset|connection/i)
      expect(error.callback_args[:arg]).to eq("connection_arg")
    end
  end

  describe "HTTP error responses" do
    it "calls success worker for 4xx responses (they are valid HTTP responses)" do
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)
      request = client.async_get("/test/404")

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "404-test", "args" => []},
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker",
        callback_args: {"status" => "missing"}
      )

      processor.enqueue(request_task)
      processor.wait_for_idle

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # 404 is a valid HTTP response, so success worker is called
      expect(TestWorkers::CompletionWorker.calls.size).to eq(1)
      expect(TestWorkers::ErrorWorker.calls.size).to eq(0)

      response = TestWorkers::CompletionWorker.calls.first.first
      expect(response.status).to eq(404)
      expect(response.client_error?).to be true
      expect(response.callback_args[:status]).to eq("missing")
    end

    it "calls success worker for 5xx responses (they are valid HTTP responses)" do
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)
      request = client.async_get("/test/503")

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "503-test", "args" => []},
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker",
        callback_args: {"status" => "unavailable"}
      )

      processor.enqueue(request_task)
      processor.wait_for_idle

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # 503 is a valid HTTP response, so success worker is called
      expect(TestWorkers::CompletionWorker.calls.size).to eq(1)
      expect(TestWorkers::ErrorWorker.calls.size).to eq(0)

      response = TestWorkers::CompletionWorker.calls.first.first
      expect(response.status).to eq(503)
      expect(response.server_error?).to be true
      expect(response.callback_args[:status]).to eq("unavailable")
    end

    it "calls error worker with HttpError when raise_error_responses is enabled" do
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)
      request = client.async_get("/test/404")

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "404-error-test", "args" => []},
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker",
        callback_args: {"status" => "missing"},
        raise_error_responses: true
      )

      processor.enqueue(request_task)
      processor.wait_for_idle

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # With raise_error_responses, 404 should call error worker with HttpError
      expect(TestWorkers::ErrorWorker.calls.size).to eq(1)
      expect(TestWorkers::CompletionWorker.calls.size).to eq(0)

      error = TestWorkers::ErrorWorker.calls.first.first
      expect(error).to be_a(Sidekiq::AsyncHttp::HttpError)
      expect(error.status).to eq(404)
      expect(error.url).to include("/test/404")
      expect(error.http_method).to eq(:get)
      expect(error.response).to be_a(Sidekiq::AsyncHttp::Response)
      expect(error.response.status).to eq(404)
      expect(error.response.client_error?).to be true
      expect(error.callback_args[:status]).to eq("missing")
    end
  end
end
