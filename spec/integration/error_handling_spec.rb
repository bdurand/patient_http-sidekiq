# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Error Handling Integration", :integration do
  include Async::RSpec::Reactor

  let(:config) do
    Sidekiq::AsyncHttp::Configuration.new.tap do |c|
      c.max_connections = 10
      c.default_request_timeout = 5
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
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "timeout-test", "args" => ["timeout_arg"]},
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker"
      )

      processor.enqueue(request_task)
      processor.wait_for_idle

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # Verify error worker was called
      expect(TestWorkers::ErrorWorker.calls.size).to eq(1)
      expect(TestWorkers::CompletionWorker.calls.size).to eq(0)

      error, *original_args = TestWorkers::ErrorWorker.calls.first
      expect(error).to be_a(Sidekiq::AsyncHttp::Error)
      expect(error.error_type).to eq(:timeout)
      expect(error.error_class.name).to match(/Timeout/)
      expect(original_args).to eq(["timeout_arg"])
    end
  end

  describe "connection errors" do
    it "calls error worker with connection error when server is not listening" do
      # Make request to a port that's not listening
      client = Sidekiq::AsyncHttp::Client.new(base_url: "http://127.0.0.1:1", connect_timeout: 0.1)
      request = client.async_get("/nowhere")

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "conn-test", "args" => ["connection_arg"]},
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker"
      )

      processor.enqueue(request_task)
      processor.wait_for_idle

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # Verify error worker was called
      expect(TestWorkers::ErrorWorker.calls.size).to eq(1)
      expect(TestWorkers::CompletionWorker.calls.size).to eq(0)

      error, *original_args = TestWorkers::ErrorWorker.calls.first
      expect(error).to be_a(Sidekiq::AsyncHttp::Error)
      expect(error.error_type).to eq(:connection)
      expect(error.error_class.name).to match(/Errno::E/)
      expect(error.message).to match(/refused|reset|connection/i)
      expect(original_args).to eq(["connection_arg"])
    end
  end

  describe "HTTP error responses" do
    it "calls success worker for 4xx responses (they are valid HTTP responses)" do
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)
      request = client.async_get("/test/404")

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "404-test", "args" => ["missing"]},
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker"
      )

      processor.enqueue(request_task)
      processor.wait_for_idle

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # 404 is a valid HTTP response, so success worker is called
      expect(TestWorkers::CompletionWorker.calls.size).to eq(1)
      expect(TestWorkers::ErrorWorker.calls.size).to eq(0)

      response, *args = TestWorkers::CompletionWorker.calls.first
      expect(response.status).to eq(404)
      expect(response.client_error?).to be true
      expect(args).to eq(["missing"])
    end

    it "calls success worker for 5xx responses (they are valid HTTP responses)" do
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)
      request = client.async_get("/test/503")

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "503-test", "args" => ["unavailable"]},
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker"
      )

      processor.enqueue(request_task)
      processor.wait_for_idle

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # 503 is a valid HTTP response, so success worker is called
      expect(TestWorkers::CompletionWorker.calls.size).to eq(1)
      expect(TestWorkers::ErrorWorker.calls.size).to eq(0)

      response, *args = TestWorkers::CompletionWorker.calls.first
      expect(response.status).to eq(503)
      expect(response.server_error?).to be true
      expect(args).to eq(["unavailable"])
    end
  end

  describe "error worker not provided" do
    it "logs error and does not crash when error_worker is nil" do
      # Make request to non-existent server without error_worker
      client = Sidekiq::AsyncHttp::Client.new(base_url: "http://127.0.0.1:1", connect_timeout: 0.1)
      request = client.async_get("/nowhere")

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "no-error-worker", "args" => ["test"]},
        completion_worker: "TestWorkers::CompletionWorker"
        # Note: no error_worker provided
      )

      processor.enqueue(request_task)
      processor.wait_for_idle

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # Neither worker should be called (error was logged)
      expect(TestWorkers::CompletionWorker.calls.size).to eq(0)
      expect(TestWorkers::ErrorWorker.calls.size).to eq(0)

      # Verify metrics recorded the error
      expect(processor.metrics.error_count).to eq(1)
      expect(processor.metrics.errors_by_type[:connection]).to eq(1)
    end
  end
end
