# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Full Workflow Integration", :integration do
  include Async::RSpec::Reactor

  let(:config) do
    Sidekiq::AsyncHttp::Configuration.new.tap do |c|
      c.max_connections = 10
      c.default_request_timeout = 5
      c.http2_enabled = false # WEBrick only supports HTTP/1.1
    end
  end

  let(:processor) { Sidekiq::AsyncHttp::Processor.new(config) }

  before do
    TestWorkers::Worker.reset_calls!
    TestWorkers::SuccessWorker.reset_calls!
    TestWorkers::ErrorWorker.reset_calls!
    @test_server = nil

    # Disable WebMock completely for integration tests
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
  end

  after do
    processor.stop(timeout: 1) if processor.running?
    cleanup_server(@test_server) if @test_server

    # Re-enable WebMock
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  describe "successful POST request workflow" do
    it "makes async POST request and calls success worker with response and original args" do
      # Start test HTTP server returning 200 OK
      @test_server = with_test_server do |s|
        s.on_request do |request|
          # Verify request details
          expect(request.method).to eq("POST")
          expect(request.path).to eq("/webhooks")
          expect(request.headers["content-type"]).to eq("application/json")
          expect(request.headers["x-custom-header"]).to eq("test-value")

          body = request.body.read
          expect(body).to eq('{"event":"user.created","user_id":123}')

          {
            status: 200,
            body: '{"success":true,"id":"webhook-123"}',
            headers: {"Content-Type" => "application/json"}
          }
        end
      end

      # Start processor
      processor.start
      expect(processor.running?).to be true

      # Build request
      client = Sidekiq::AsyncHttp::Client.new(base_url: @test_server.url)
      request = client.async_post(
        "/webhooks",
        body: '{"event":"user.created","user_id":123}',
        headers: {
          "Content-Type" => "application/json",
          "X-Custom-Header" => "test-value"
        }
      )

      # Create request task with test workers
      sidekiq_job = {
        "class" => "TestWorkers::Worker",
        "jid" => "test-jid-123",
        "args" => ["webhook_id", 1]
      }

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: "TestWorkers::SuccessWorker",
        error_worker: "TestWorkers::ErrorWorker"
      )

      # Enqueue request
      processor.enqueue(request_task)

      # Wait for request to complete
      processor.wait_for_idle(timeout: 2)

      # Process enqueued Sidekiq jobs
      Sidekiq::Worker.drain_all

      # Verify TestSuccessWorker was called
      expect(TestWorkers::SuccessWorker.calls.size).to eq(1)

      # Verify response details
      response, *original_args = TestWorkers::SuccessWorker.calls.first

      # Verify response hash contains correct status, body
      expect(response).to be_a(Sidekiq::AsyncHttp::Response)
      expect(response.status).to eq(200)
      expect(response.body).to eq('{"success":true,"id":"webhook-123"}')
      expect(response.headers["content-type"]).to eq("application/json")
      expect(response.success?).to be true

      # Verify original_args passed through correctly
      expect(original_args).to eq(["webhook_id", 1])

      # Verify no error worker was called
      expect(TestWorkers::ErrorWorker.calls).to be_empty
    end
  end

  describe "successful GET request workflow" do
    it "makes async GET request and calls success worker" do
      # Start test HTTP server returning 200 OK
      @test_server = with_test_server do |s|
        s.on_request do |request|
          expect(request.method).to eq("GET")
          expect(request.path).to eq("/users/123")
          expect(request.headers["authorization"]).to eq("Bearer token123")

          {
            status: 200,
            body: '{"id":123,"name":"John Doe"}',
            headers: {"Content-Type" => "application/json"}
          }
        end
      end

      # Start processor
      processor.start

      # Build request
      client = Sidekiq::AsyncHttp::Client.new(base_url: @test_server.url)
      request = client.async_get(
        "/users/123",
        headers: {"Authorization" => "Bearer token123"}
      )

      # Create request task
      sidekiq_job = {
        "class" => "TestWorkers::Worker",
        "jid" => "test-jid-456",
        "args" => ["user", 123, "fetch"]
      }

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: "TestWorkers::SuccessWorker"
      )

      # Enqueue and wait
      processor.enqueue(request_task)
      processor.wait_for_idle(timeout: 2)

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # Verify success worker called
      expect(TestWorkers::SuccessWorker.calls.size).to eq(1)

      response, *args = TestWorkers::SuccessWorker.calls.first
      expect(response.status).to eq(200)
      expect(response.body).to eq('{"id":123,"name":"John Doe"}')
      expect(args).to eq(["user", 123, "fetch"])
    end
  end

  describe "multiple concurrent requests" do
    it "handles multiple requests with different responses" do
      # Setup server to handle multiple endpoints
      request_count = 0
      @test_server = with_test_server do |s|
        s.on_request do |request|
          request_count += 1
          case request.path
          when "/endpoint1"
            {status: 200, body: "response1"}
          when "/endpoint2"
            {status: 201, body: "response2"}
          when "/endpoint3"
            {status: 202, body: "response3"}
          else
            {status: 404, body: "Not found"}
          end
        end
      end

      processor.start

      client = Sidekiq::AsyncHttp::Client.new(base_url: @test_server.url)

      # Enqueue 3 requests
      3.times do |i|
        request = client.async_get("/endpoint#{i + 1}")
        request_task = Sidekiq::AsyncHttp::RequestTask.new(
          request: request,
          sidekiq_job: {
            "class" => "TestWorkers::Worker",
            "jid" => "jid-#{i}",
            "args" => [i]
          },
          success_worker: "TestWorkers::SuccessWorker"
        )
        processor.enqueue(request_task)
      end

      # Wait for all to complete
      processor.wait_for_idle(timeout: 2)

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # Verify all 3 success workers called
      expect(TestWorkers::SuccessWorker.calls.size).to eq(3)

      # Verify each got correct response
      responses = TestWorkers::SuccessWorker.calls.map { |call| call.first }
      statuses = responses.map(&:status).sort
      bodies = responses.map(&:body).sort

      expect(statuses).to eq([200, 201, 202])
      expect(bodies).to eq(%w[response1 response2 response3])
    end
  end

  describe "request with params and headers" do
    it "properly encodes params and sends headers" do
      @test_server = with_test_server do |s|
        s.on_request do |request|
          expect(request.path).to include("/search")
          expect(request.path).to include("q=ruby")
          expect(request.path).to include("page=2")
          expect(request.path).to include("limit=50")
          expect(request.headers["authorization"]).to eq("Bearer secret")
          expect(request.headers["x-api-version"]).to eq("v2")

          {status: 200, body: "search results"}
        end
      end

      processor.start

      client = Sidekiq::AsyncHttp::Client.new(base_url: @test_server.url)
      request = client.async_get(
        "/search",
        params: {"q" => "ruby", "page" => "2", "limit" => "50"},
        headers: {
          "Authorization" => "Bearer secret",
          "X-Api-Version" => "v2"
        }
      )

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "jid", "args" => []},
        success_worker: "TestWorkers::SuccessWorker"
      )

      processor.enqueue(request_task)
      processor.wait_for_idle(timeout: 2)

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      expect(TestWorkers::SuccessWorker.calls.size).to eq(1)
      response = TestWorkers::SuccessWorker.calls.first.first
      expect(response.status).to eq(200)
      expect(response.body).to eq("search results")
    end
  end

  describe "processor lifecycle" do
    it "can be started and stopped cleanly" do
      @test_server = with_test_server do |s|
        s.on_request do |request|
          {status: 200, body: "ok"}
        end
      end

      # Start processor
      processor.start
      expect(processor.running?).to be true

      # Make a request
      client = Sidekiq::AsyncHttp::Client.new(base_url: @test_server.url)
      request = client.async_get("/test")
      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "jid", "args" => []},
        success_worker: "TestWorkers::SuccessWorker"
      )

      processor.enqueue(request_task)
      processor.wait_for_idle(timeout: 2)

      # Stop processor
      processor.stop(timeout: 1)
      expect(processor.stopped?).to be true

      # Process enqueued jobs
      Sidekiq::Worker.drain_all

      # Verify request completed
      expect(TestWorkers::SuccessWorker.calls.size).to eq(1)
    end
  end
end
