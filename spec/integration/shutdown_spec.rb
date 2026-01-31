# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Processor Shutdown Integration", :integration do
  include Async::RSpec::Reactor

  let(:config) do
    Sidekiq::AsyncHttp::Configuration.new.tap do |c|
      c.max_connections = 10
      c.request_timeout = 10
    end
  end

  let!(:processor) { Sidekiq::AsyncHttp::Processor.new(config) }

  around do |example|
    processor.run do
      example.run
    end
  end

  before do
    # Clear any pending Sidekiq jobs first
    Sidekiq::Queues.clear_all

    # Reset all worker call tracking
    TestWorkers::Worker.reset_calls!
    TestWorkers::CompletionWorker.reset_calls!
    TestWorkers::ErrorWorker.reset_calls!

    # Disable WebMock completely for integration tests
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!

    # Keep fake mode so jobs queue but don't execute immediately
    Sidekiq::Testing.fake!
  end

  after do
    # Re-enable WebMock
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  describe "clean shutdown with completion" do
    it "allows in-flight requests to complete when timeout is sufficient" do
      # Build request
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)
      request = client.async_get("/test/200")

      # Create request task
      sidekiq_job = {
        "class" => "TestWorkers::Worker",
        "jid" => "test-jid-clean",
        "args" => []
      }

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker",
        callback_args: {arg1: "arg1", arg2: "arg2"}
      )

      # Enqueue request
      processor.enqueue(request_task)

      # Wait for request to complete
      processor.wait_for_idle(timeout: 2)

      # Stop with sufficient timeout (2 seconds for a fast request)
      processor.stop

      # Drain all completion/error worker jobs
      Sidekiq::Worker.drain_all

      # Verify success worker was called (request completed)
      expect(TestWorkers::CompletionWorker.calls.size).to eq(1)
      response = TestWorkers::CompletionWorker.calls.first.first
      expect(response).to be_a(Sidekiq::AsyncHttp::Response)
      expect(response.status).to eq(200)
      # Verify response contains request info
      response_data = JSON.parse(response.body)
      expect(response_data["status"]).to eq(200)
      expect(response.callback_args[:arg1]).to eq("arg1")
      expect(response.callback_args[:arg2]).to eq("arg2")

      # Verify original worker was NOT re-enqueued
      expect(TestWorkers::Worker.calls).to be_empty

      # Verify processor is stopped
      expect(processor.stopped?).to be true
    end
  end

  describe "forced shutdown with re-enqueue" do
    it "re-enqueues in-flight requests when timeout is insufficient" do
      # Build request
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)
      request = client.async_get("/delay/250")

      # Create request task
      sidekiq_job = {
        "class" => "TestWorkers::Worker",
        "jid" => "test-jid-forced",
        "args" => %w[original_arg1 original_arg2]
      }

      request_task = Sidekiq::AsyncHttp::RequestTask.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker"
      )

      # Enqueue request
      processor.enqueue(request_task)

      # Wait for request to start processing
      processor.wait_for_processing
      # Give it a bit more time to really get in-flight
      sleep(0.05)

      # Stop with insufficient timeout (0.01 seconds for a 250ms request)
      processor.stop(timeout: 0.01)

      # Wait briefly for re-enqueue to happen
      sleep(0.05)

      # Drain all re-enqueued jobs
      Sidekiq::Worker.drain_all

      # Verify original worker was re-enqueued and executed
      expect(TestWorkers::Worker.calls.size).to eq(1)
      arg1, arg2 = TestWorkers::Worker.calls.first
      expect(arg1).to eq("original_arg1")
      expect(arg2).to eq("original_arg2")

      # Verify success worker was NOT called (request did not complete)
      expect(TestWorkers::CompletionWorker.calls).to be_empty

      # Verify processor is stopped
      expect(processor.stopped?).to be true
    end
  end

  describe "multiple in-flight requests during shutdown" do
    it "completes fast requests and re-enqueues slow requests" do
      # Build and enqueue 5 requests
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)
      request_tasks = []

      5.times do |i|
        request = client.async_get("/delay/#{i.even? ? 100 : 500}")

        sidekiq_job = {
          "class" => "TestWorkers::Worker",
          "jid" => "test-jid-#{i + 1}",
          "args" => ["request_#{i + 1}"]
        }

        request_task = Sidekiq::AsyncHttp::RequestTask.new(
          request: request,
          sidekiq_job: sidekiq_job,
          completion_worker: "TestWorkers::CompletionWorker",
          error_worker: "TestWorkers::ErrorWorker",
          callback_args: {request_name: "request_#{i + 1}"}
        )

        processor.enqueue(request_task)
        request_tasks << request_task
      end

      processor.wait_for_processing
      # Wait a bit longer to let fast requests (100ms) get close to completion
      sleep(0.15)

      # Stop with medium timeout (200ms)
      # Fast requests (100ms) should complete during this timeout
      # Slow requests (500ms) should be re-enqueued
      processor.stop(timeout: 0.2)

      # Wait briefly for re-enqueue to happen
      sleep(0.05)

      # Drain any re-enqueued jobs
      Sidekiq::Worker.drain_all

      # Verify success worker was called for fast requests (1, 3, 5)
      expect(TestWorkers::CompletionWorker.calls.size).to eq(3)
      success_args = TestWorkers::CompletionWorker.calls.map { |call| call.first.callback_args[:request_name] }
      expect(success_args).to contain_exactly("request_1", "request_3", "request_5")

      # Verify original worker was called for slow requests (2, 4)
      expect(TestWorkers::Worker.calls.size).to eq(2)
      worker_args = TestWorkers::Worker.calls.map { |call| call[0] }
      expect(worker_args).to contain_exactly("request_2", "request_4")

      # Verify total callbacks equals 5 (all requests accounted for)
      total_callbacks = TestWorkers::CompletionWorker.calls.size + TestWorkers::Worker.calls.size
      expect(total_callbacks).to eq(5)

      # Verify processor is stopped
      expect(processor.stopped?).to be true
    end
  end
end
