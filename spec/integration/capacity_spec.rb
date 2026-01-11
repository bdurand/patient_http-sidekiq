# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Capacity Limit Integration", :integration do
  include Async::RSpec::Reactor

  let(:config) do
    Sidekiq::AsyncHttp::Configuration.new.tap do |c|
      c.max_connections = 2 # Set low limit for testing
      c.default_request_timeout = 10
      c.http2_enabled = false
    end
  end

  let!(:processor) { Sidekiq::AsyncHttp::Processor.new(config) }

  before do
    # Clear any pending Sidekiq jobs first
    Sidekiq::Queues.clear_all

    # Reset all worker call tracking
    TestWorkers::Worker.reset_calls!
    TestWorkers::SuccessWorker.reset_calls!
    TestWorkers::ErrorWorker.reset_calls!

    # Disable WebMock completely for integration tests
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!

    Sidekiq::Testing.fake!

    processor.start
  end

  after do
    # Stop processor with minimal timeout
    processor.stop(timeout: 0) if processor.running?

    # Re-enable WebMock
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  describe "enforcing max_connections limit" do
    it "raises error when attempting to exceed capacity and allows enqueue after request completes" do
      # Build client
      client = Sidekiq::AsyncHttp::Client.new(base_url: test_web_server.base_url)

      # Enqueue first long-running request
      request1 = client.async_get("/delay/250")
      request_task1 = Sidekiq::AsyncHttp::RequestTask.new(
        request: request1,
        sidekiq_job: {
          "class" => "TestWorkers::Worker",
          "jid" => "jid-1",
          "args" => ["arg1"]
        },
        success_worker: "TestWorkers::SuccessWorker",
        error_worker: "TestWorkers::ErrorWorker"
      )
      processor.enqueue(request_task1)

      # Enqueue second long-running request
      request2 = client.async_get("/delay/250")
      request_task2 = Sidekiq::AsyncHttp::RequestTask.new(
        request: request2,
        sidekiq_job: {
          "class" => "TestWorkers::Worker",
          "jid" => "jid-2",
          "args" => ["arg2"]
        },
        success_worker: "TestWorkers::SuccessWorker",
        error_worker: "TestWorkers::ErrorWorker"
      )
      processor.enqueue(request_task2)

      # Wait for both requests to start processing
      processor.wait_for_processing

      # Attempt to enqueue third request - should raise error
      request3 = client.async_get("/delay/100")
      request_task3 = Sidekiq::AsyncHttp::RequestTask.new(
        request: request3,
        sidekiq_job: {
          "class" => "TestWorkers::Worker",
          "jid" => "jid-3",
          "args" => ["arg3"]
        },
        success_worker: "TestWorkers::SuccessWorker",
        error_worker: "TestWorkers::ErrorWorker"
      )

      # Should raise error due to capacity limit
      expect {
        processor.enqueue(request_task3)
      }.to raise_error(Sidekiq::AsyncHttp::MaxCapacityError)

      # Verify still only 2 in-flight
      expect(processor.metrics.in_flight_count).to eq(2)

      # Wait for the first two requests to complete
      processor.wait_for_idle

      # Verify both completed
      expect(processor.metrics.in_flight_count).to eq(0)

      # Now we should be able to enqueue the third request
      expect {
        processor.enqueue(request_task3)
      }.not_to raise_error

      # Wait for third request to complete
      processor.wait_for_idle

      # Process all callbacks
      Sidekiq::Worker.drain_all

      # Verify all 3 requests completed successfully
      expect(TestWorkers::SuccessWorker.calls.size).to eq(3)
      expect(TestWorkers::ErrorWorker.calls.size).to eq(0)

      # Verify no errors in metrics
      expect(processor.metrics.error_count).to eq(0)

      # Verify processor is still running
      expect(processor.running?).to be true
    end
  end
end
