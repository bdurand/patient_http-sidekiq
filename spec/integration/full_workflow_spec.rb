# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Full Workflow Integration", :integration do
  include Async::RSpec::Reactor

  let(:config) do
    Sidekiq::AsyncHttp::Configuration.new.tap do |c|
      c.max_connections = 10
      c.request_timeout = 5
    end
  end

  let(:processor) { Sidekiq::AsyncHttp::Processor.new(config) }

  around do |example|
    TestCallback.reset_calls!

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

  describe "successful POST request workflow" do
    it "makes async POST request and calls success worker with response containing callback_args" do
      # Build request
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)
      request = client.async_post(
        "/test/200",
        body: '{"event":"user.created","user_id":123}',
        headers: {
          "Content-Type" => "application/json",
          "X-Custom-Header" => "test-value"
        }
      )

      # Create request task with test callback
      sidekiq_job = {
        "class" => "TestWorker",
        "jid" => "test-jid-123",
        "args" => []
      }

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job,
        callback: TestCallback,
        callback_args: {webhook_id: "webhook_id", index: 1}
      )

      # Enqueue request
      processor.enqueue(request_task)

      # Wait for request to complete
      processor.wait_for_idle(timeout: 2)

      # Process enqueued Sidekiq jobs
      Sidekiq::Worker.drain_all

      # Verify TestCallback on_complete was called
      expect(TestCallback.completion_calls.size).to eq(1)

      # Verify response details
      response = TestCallback.completion_calls.first

      # Verify response hash contains correct status, body
      expect(response).to be_a(Sidekiq::AsyncHttp::Response)
      expect(response.status).to eq(200)

      # Parse the response body JSON
      response_data = JSON.parse(response.body)
      expect(response_data["status"]).to eq(200)
      expect(response_data["body"]).to eq('{"event":"user.created","user_id":123}')
      expect(response_data["headers"]["content-type"]).to eq("application/json")

      expect(response.headers["content-type"]).to eq("application/json")
      expect(response.success?).to be true

      # Verify callback_args passed through correctly
      expect(response.callback_args[:webhook_id]).to eq("webhook_id")
      expect(response.callback_args[:index]).to eq(1)

      # Verify no error callback was called
      expect(TestCallback.error_calls).to be_empty
    end
  end

  describe "successful GET request workflow" do
    it "makes async GET request and calls success worker" do
      # Build request
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)
      request = client.async_get(
        "/test/200",
        headers: {"Authorization" => "Bearer token123"}
      )

      # Create request task
      sidekiq_job = {
        "class" => "TestWorker",
        "jid" => "test-jid-456",
        "args" => []
      }

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job,
        callback: TestCallback,
        callback_args: {resource: "user", id: 123, action: "fetch"}
      )

      # Enqueue and wait
      processor.enqueue(request_task)
      processor.wait_for_idle(timeout: 2)

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # Verify on_complete was called
      expect(TestCallback.completion_calls.size).to eq(1)

      response = TestCallback.completion_calls.first
      expect(response.status).to eq(200)

      # Verify response contains request info
      response_data = JSON.parse(response.body)
      expect(response_data["status"]).to eq(200)
      expect(response_data["headers"]["authorization"]).to eq("Bearer token123")
      expect(response.callback_args[:resource]).to eq("user")
      expect(response.callback_args[:id]).to eq(123)
      expect(response.callback_args[:action]).to eq("fetch")
    end
  end

  describe "multiple concurrent requests" do
    it "handles multiple requests with different responses" do
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)

      # Enqueue 3 requests with different status codes
      [200, 201, 202].each_with_index do |status, i|
        request = client.async_get("/test/#{status}")
        request_task = Sidekiq::AsyncHttp::RequestTask.new(
          request: request,
          sidekiq_job: {
            "class" => "TestWorker",
            "jid" => "jid-#{i}",
            "args" => [i]
          },
          callback: TestCallback
        )
        processor.enqueue(request_task)
      end

      # Wait for all to complete
      processor.wait_for_idle(timeout: 2)

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # Verify all 3 on_complete callbacks called
      expect(TestCallback.completion_calls.size).to eq(3)

      # Verify each got correct response
      responses = TestCallback.completion_calls
      statuses = responses.map(&:status).sort

      expect(statuses).to eq([200, 201, 202])
    end
  end

  describe "request with params and headers" do
    it "properly encodes params and sends headers" do
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)
      request = client.async_get(
        "/test/200",
        params: {"q" => "ruby", "page" => "2", "limit" => "50"},
        headers: {
          "Authorization" => "Bearer secret",
          "X-Api-Version" => "v2"
        }
      )

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorker", "jid" => "jid", "args" => []},
        callback: TestCallback
      )

      processor.enqueue(request_task)
      processor.wait_for_idle(timeout: 2)

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      expect(TestCallback.completion_calls.size).to eq(1)
      response = TestCallback.completion_calls.first
      expect(response.status).to eq(200)

      # Verify params and headers were sent
      response_data = JSON.parse(response.body)
      expect(response_data["query_string"]).to include("q=ruby")
      expect(response_data["query_string"]).to include("page=2")
      expect(response_data["query_string"]).to include("limit=50")
      expect(response_data["headers"]["authorization"]).to eq("Bearer secret")
      expect(response_data["headers"]["x-api-version"]).to eq("v2")
    end
  end

  describe "processor lifecycle" do
    it "can be started and stopped cleanly" do
      # Make a request
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)
      request = client.async_get("/test/200")
      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorker", "jid" => "jid", "args" => []},
        callback: TestCallback
      )

      processor.enqueue(request_task)
      processor.wait_for_idle(timeout: 2)

      # Stop processor
      processor.stop(timeout: 1)
      expect(processor.stopped?).to be true

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # Verify request completed
      expect(TestCallback.completion_calls.size).to eq(1)
    end
  end
end
