# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Sidekiq::Testing.inline! mode" do
  before do
    # Save the original testing mode (Sidekiq::Testing stores it as a class variable)
    # Note: nil means we should default to fake mode (as set in spec_helper.rb)
    @original_testing_mode = Sidekiq::Testing.instance_variable_get(:@test_mode) || :fake

    # Enable inline testing mode
    Sidekiq::Testing.inline!

    # Clear any pending jobs
    Sidekiq::Queues.clear_all

    # Reset worker call tracking
    TestWorkers::Worker.reset_calls!
    TestWorkers::CompletionWorker.reset_calls!
    TestWorkers::ErrorWorker.reset_calls!

    # Enable WebMock for inline tests
    WebMock.enable!
    WebMock.reset!
  end

  after do
    # Restore the original testing mode
    if @original_testing_mode == :fake
      Sidekiq::Testing.fake!
    elsif @original_testing_mode == :inline
      Sidekiq::Testing.inline!
    else
      Sidekiq::Testing.disable!
    end
  end

  describe "successful HTTP request" do
    it "executes HTTP request inline and calls completion worker inline" do
      # Stub HTTP request
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: '{"users": []}', headers: {"Content-Type" => "application/json"})

      client = Sidekiq::AsyncHttp::Client.new(base_url: "https://api.example.com")
      request = client.async_get("/users")

      # Execute request
      request.execute(
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "test-123", "args" => []},
        completion_worker: TestWorkers::CompletionWorker,
        error_worker: TestWorkers::ErrorWorker,
        callback_args: {arg1: "arg1", arg2: "arg2"}
      )

      # Verify completion worker was called inline (not enqueued)
      expect(TestWorkers::CompletionWorker.calls.size).to eq(1)

      response = TestWorkers::CompletionWorker.calls.first.first
      expect(response).to be_a(Sidekiq::AsyncHttp::Response)
      expect(response.status).to eq(200)
      expect(response.body).to eq('{"users": []}')
      expect(response.callback_args[:arg1]).to eq("arg1")
      expect(response.callback_args[:arg2]).to eq("arg2")

      # Verify no jobs were enqueued
      expect(TestWorkers::CompletionWorker.jobs.size).to eq(0)
    end

    it "handles POST requests with body inline" do
      stub_request(:post, "https://api.example.com/users")
        .with(body: '{"name":"John"}')
        .to_return(status: 201, body: '{"id": 123}', headers: {"Content-Type" => "application/json"})

      client = Sidekiq::AsyncHttp::Client.new(base_url: "https://api.example.com")
      request = client.async_post("/users", json: {name: "John"})

      request.execute(
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "test-456", "args" => []},
        completion_worker: TestWorkers::CompletionWorker,
        error_worker: TestWorkers::ErrorWorker,
        callback_args: {action: "create"}
      )

      expect(TestWorkers::CompletionWorker.calls.size).to eq(1)
      response = TestWorkers::CompletionWorker.calls.first.first
      expect(response.status).to eq(201)
      expect(response.body).to eq('{"id": 123}')
      expect(response.callback_args[:action]).to eq("create")
    end

    it "handles 4xx and 5xx responses as successful (they are valid HTTP responses)" do
      stub_request(:get, "https://api.example.com/missing").to_return(status: 404, body: "Not Found")

      client = Sidekiq::AsyncHttp::Client.new(base_url: "https://api.example.com")
      request = client.async_get("/missing")

      request.execute(
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "test-404", "args" => []},
        completion_worker: TestWorkers::CompletionWorker,
        error_worker: TestWorkers::ErrorWorker
      )

      # 404 is a valid HTTP response, so completion worker is called
      expect(TestWorkers::CompletionWorker.calls.size).to eq(1)
      expect(TestWorkers::ErrorWorker.calls.size).to eq(0)

      response = TestWorkers::CompletionWorker.calls.first.first
      expect(response.status).to eq(404)
      expect(response.client_error?).to be true
    end
  end

  describe "failed HTTP request with error worker" do
    it "executes HTTP request inline and calls error worker inline on connection error" do
      # Stub connection error
      stub_request(:get, "https://api.example.com/users").to_raise(Errno::ECONNREFUSED)

      client = Sidekiq::AsyncHttp::Client.new(base_url: "https://api.example.com")
      request = client.async_get("/users")

      request.execute(
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "test-error", "args" => []},
        completion_worker: TestWorkers::CompletionWorker,
        error_worker: TestWorkers::ErrorWorker,
        callback_args: {arg1: "arg1"}
      )

      # Verify error worker was called inline
      expect(TestWorkers::ErrorWorker.calls.size).to eq(1)
      expect(TestWorkers::CompletionWorker.calls.size).to eq(0)

      error = TestWorkers::ErrorWorker.calls.first.first
      expect(error).to be_a(Sidekiq::AsyncHttp::Error)
      expect(error.error_class).to eq(Errno::ECONNREFUSED)
      expect(error.callback_args[:arg1]).to eq("arg1")

      # Verify no jobs were enqueued
      expect(TestWorkers::ErrorWorker.jobs.size).to eq(0)
    end

    it "handles timeout errors inline" do
      # Stub timeout error
      stub_request(:get, "https://api.example.com/slow")
        .to_timeout

      client = Sidekiq::AsyncHttp::Client.new(base_url: "https://api.example.com")
      request = client.async_get("/slow")

      request.execute(
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "test-timeout", "args" => []},
        completion_worker: TestWorkers::CompletionWorker,
        error_worker: TestWorkers::ErrorWorker,
        callback_args: {action: "slow"}
      )

      expect(TestWorkers::ErrorWorker.calls.size).to eq(1)
      expect(TestWorkers::CompletionWorker.calls.size).to eq(0)

      error = TestWorkers::ErrorWorker.calls.first.first
      expect(error).to be_a(Sidekiq::AsyncHttp::Error)
      expect(error.callback_args[:action]).to eq("slow")
    end
  end
  describe "with custom headers" do
    it "includes custom headers in the inline request" do
      stub_request(:get, "https://api.example.com/secure")
        .with(headers: {"Authorization" => "Bearer token123"})
        .to_return(status: 200, body: "OK")

      client = Sidekiq::AsyncHttp::Client.new(base_url: "https://api.example.com")
      request = client.async_get("/secure", headers: {"Authorization" => "Bearer token123"})

      request.execute(
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "test-headers", "args" => []},
        completion_worker: TestWorkers::CompletionWorker,
        error_worker: TestWorkers::ErrorWorker
      )

      expect(TestWorkers::CompletionWorker.calls.size).to eq(1)
      response = TestWorkers::CompletionWorker.calls.first.first
      expect(response.status).to eq(200)
    end
  end
end
