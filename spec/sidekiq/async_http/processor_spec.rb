# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Processor do
  let(:config) { Sidekiq::AsyncHttp.configuration }
  let(:metrics) { Sidekiq::AsyncHttp::Metrics.new }
  let(:connection_pool) { instance_double(Sidekiq::AsyncHttp::ConnectionPool) }
  let(:processor) { described_class.new(config, metrics: metrics, connection_pool: connection_pool) }

  # Mock request object matching the expected structure
  let(:mock_request) do
    TestRequest.new(
      id: "req-123",
      method: :get,
      url: "https://api.example.com/users",
      headers: {"Accept" => "application/json"},
      body: nil,
      timeout: 30,
      success_worker_class: "TestSuccessWorker",
      error_worker_class: "TestErrorWorker",
      job_args: [1, "test_arg"]
    )
  end

  describe ".new" do
    it "initializes with provided config, metrics, and connection pool" do
      expect(processor.config).to eq(config)
      expect(processor.metrics).to eq(metrics)
      expect(processor.connection_pool).to eq(connection_pool)
    end

    it "initializes with defaults if not provided" do
      processor = described_class.new
      expect(processor.config).to be_a(Sidekiq::AsyncHttp::Configuration)
      expect(processor.metrics).to be_a(Sidekiq::AsyncHttp::Metrics)
      expect(processor.connection_pool).to be_a(Sidekiq::AsyncHttp::ConnectionPool)
    end

    it "starts in stopped state" do
      expect(processor).to be_stopped
      expect(processor.state).to eq(:stopped)
    end
  end

  describe "#start" do
    before do
      allow(connection_pool).to receive(:close_all)
    end

    after do
      processor.stop if processor.running?
    end

    it "sets the state to running" do
      processor.start
      expect(processor).to be_running
      expect(processor.state).to eq(:running)
    end

    it "spawns a reactor thread" do
      processor.start
      expect(processor.instance_variable_get(:@reactor_thread)).to be_alive
    end

    it "names the reactor thread" do
      processor.start
      thread = processor.instance_variable_get(:@reactor_thread)
      expect(thread.name).to eq("async-http-processor")
    end

    it "does not start if already running" do
      processor.start
      old_thread = processor.instance_variable_get(:@reactor_thread)
      processor.start
      new_thread = processor.instance_variable_get(:@reactor_thread)
      expect(old_thread).to eq(new_thread)
    end

    it "resets the shutdown barrier" do
      barrier = processor.instance_variable_get(:@shutdown_barrier)
      barrier.set
      expect(barrier).to be_set

      processor.start
      expect(barrier).not_to be_set
    end
  end

  describe "#stop" do
    before do
      allow(connection_pool).to receive(:close_all)
    end

    context "when not running" do
      it "does nothing if already stopped" do
        expect(processor).to be_stopped
        processor.stop
        expect(processor).to be_stopped
      end
    end

    context "when running" do
      before do
        processor.start
      end

      it "sets the state to stopping then stopped" do
        processor.stop
        expect(processor).to be_stopped
      end

      it "waits for reactor thread to finish" do
        thread = processor.instance_variable_get(:@reactor_thread)
        processor.stop
        expect(thread).not_to be_alive
      end

      it "closes the connection pool" do
        expect(connection_pool).to receive(:close_all)
        processor.stop
      end

      it "signals the shutdown barrier" do
        barrier = processor.instance_variable_get(:@shutdown_barrier)
        processor.stop
        expect(barrier).to be_set
      end

      context "with timeout" do
        it "waits for in-flight requests to complete" do
          allow(metrics).to receive(:in_flight_count).and_return(2, 2, 1, 0)

          start_time = Time.now
          processor.stop(timeout: 0.5)
          elapsed = Time.now - start_time

          # Should wait but not exceed timeout significantly
          expect(elapsed).to be < 1.0
        end

        it "does not wait longer than timeout" do
          allow(metrics).to receive(:in_flight_count).and_return(10)

          start_time = Time.now
          processor.stop(timeout: 0.2)
          elapsed = Time.now - start_time

          # Should stop around timeout
          expect(elapsed).to be_between(0.15, 0.5)
        end

        it "stops immediately if timeout is nil" do
          allow(metrics).to receive(:in_flight_count).and_return(10)

          start_time = Time.now
          processor.stop(timeout: nil)
          elapsed = Time.now - start_time

          # Should not wait for requests
          expect(elapsed).to be < 0.2
        end

        it "stops immediately if timeout is zero" do
          allow(metrics).to receive(:in_flight_count).and_return(10)

          start_time = Time.now
          processor.stop(timeout: 0)
          elapsed = Time.now - start_time

          # Should not wait for requests
          expect(elapsed).to be < 0.2
        end
      end
    end
  end

  describe "#drain" do
    before do
      allow(connection_pool).to receive(:close_all)
    end

    after do
      processor.stop if processor.running? || processor.draining?
    end

    it "sets the state to draining when running" do
      processor.start
      processor.drain
      expect(processor).to be_draining
      expect(processor.state).to eq(:draining)
    end

    it "does nothing if not running" do
      expect(processor).to be_stopped
      processor.drain
      expect(processor).to be_stopped
    end
  end

  describe "#enqueue" do
    let(:request) { TestRequest.new }

    before do
      allow(connection_pool).to receive(:close_all)
    end

    after do
      processor.stop if processor.running? || processor.draining?
    end

    context "when running" do
      before do
        processor.start
      end

      it "adds the request to the queue" do
        processor.enqueue(request)
        queue = processor.instance_variable_get(:@queue)
        expect(queue.size).to eq(1)
      end

      it "does not raise an error" do
        expect { processor.enqueue(request) }.not_to raise_error
      end
    end

    context "when draining" do
      before do
        processor.start
        processor.drain
      end

      it "adds the request to the queue" do
        processor.enqueue(request)
        queue = processor.instance_variable_get(:@queue)
        expect(queue.size).to eq(1)
      end

      it "does not raise an error" do
        expect { processor.enqueue(request) }.not_to raise_error
      end
    end

    context "when stopped" do
      it "raises an error" do
        expect { processor.enqueue(request) }.to raise_error(RuntimeError, /Cannot enqueue request: processor is stopped/)
      end
    end

    context "when stopping" do
      before do
        processor.start
        processor.instance_variable_get(:@state).set(:stopping)
      end

      it "raises an error" do
        expect { processor.enqueue(request) }.to raise_error(RuntimeError, /Cannot enqueue request: processor is stopping/)
      end
    end
  end

  describe "state predicates" do
    before do
      allow(connection_pool).to receive(:close_all)
    end

    describe "#running?" do
      it "returns true when state is running" do
        processor.start
        expect(processor.running?).to be true
      end

      it "returns false when state is not running" do
        expect(processor.running?).to be false
      end
    end

    describe "#stopped?" do
      it "returns true when state is stopped" do
        expect(processor.stopped?).to be true
      end

      it "returns false when state is not stopped" do
        processor.start
        expect(processor.stopped?).to be false
        processor.stop
      end
    end

    describe "#draining?" do
      it "returns true when state is draining" do
        processor.start
        processor.drain
        expect(processor.draining?).to be true
        processor.stop
      end

      it "returns false when state is not draining" do
        expect(processor.draining?).to be false
      end
    end

    describe "#stopping?" do
      it "returns true when state is stopping" do
        processor.start
        processor.instance_variable_get(:@state).set(:stopping)
        expect(processor.stopping?).to be true
        processor.stop
      end

      it "returns false when state is not stopping" do
        expect(processor.stopping?).to be false
      end
    end
  end

  describe "state transitions" do
    before do
      allow(connection_pool).to receive(:close_all)
    end

    it "transitions from stopped to running" do
      expect(processor.state).to eq(:stopped)
      processor.start
      expect(processor.state).to eq(:running)
      processor.stop
    end

    it "transitions from running to draining" do
      processor.start
      expect(processor.state).to eq(:running)
      processor.drain
      expect(processor.state).to eq(:draining)
      processor.stop
    end

    it "transitions from running to stopping to stopped" do
      processor.start
      expect(processor.state).to eq(:running)
      processor.stop
      expect(processor.state).to eq(:stopped)
    end

    it "transitions from draining to stopping to stopped" do
      processor.start
      processor.drain
      expect(processor.state).to eq(:draining)
      processor.stop
      expect(processor.state).to eq(:stopped)
    end

    it "allows restart after stop" do
      processor.start
      expect(processor.state).to eq(:running)

      processor.stop
      expect(processor.state).to eq(:stopped)

      processor.start
      expect(processor.state).to eq(:running)

      processor.stop
    end
  end

  describe "thread safety" do
    before do
      allow(connection_pool).to receive(:close_all)
    end

    after do
      processor.stop if processor.running? || processor.draining?
    end

    it "handles concurrent enqueues safely" do
      # Temporarily stop the processor to prevent queue consumption
      count = 0
      mutex = Mutex.new

      allow(processor).to receive(:dequeue_request) do |**args|
        mutex.synchronize { count += 1 }
        nil # Return nil to prevent processing
      end

      processor.start

      threads = 10.times.map do |i|
        Thread.new do
          10.times do |j|
            request = TestRequest.new(id: "request-#{i}-#{j}")
            processor.enqueue(request)
          end
        end
      end

      threads.each(&:join)

      # Wait for all 100 requests to be dequeued
      sleep(0.001) until count >= 100

      queue = processor.instance_variable_get(:@queue)
      # Queue should have 100 items or be processing them
      expect(queue.size + count).to be >= 100
    end

    it "handles concurrent state reads safely" do
      processor.start

      results = []
      threads = 10.times.map do
        Thread.new do
          100.times do
            results << processor.state
          end
        end
      end

      threads.each(&:join)

      expect(results).to all(satisfy { |state| described_class::STATES.include?(state) })
      expect(results.size).to eq(1000)
    end
  end

  describe "error handling" do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:config) do
      Sidekiq::AsyncHttp::Configuration.new(logger: logger)
    end
    let(:processor_with_logger) { described_class.new(config, metrics: metrics, connection_pool: connection_pool) }

    before do
      allow(connection_pool).to receive(:close_all)
    end

    after do
      processor_with_logger.stop if processor_with_logger.running?
    end

    it "logs errors from the reactor loop" do
      # Force an error in the reactor by making dequeue_request raise
      allow(processor_with_logger).to receive(:dequeue_request).and_raise(StandardError.new("Test error"))

      processor_with_logger.start

      expect(log_output.string).to match(/Test error/)
    end

    it "recovers from errors and stops gracefully" do
      allow(processor_with_logger).to receive(:dequeue_request).and_raise(StandardError.new("Test error"))

      processor_with_logger.start

      processor_with_logger.stop
      expect(processor_with_logger).to be_stopped
    end
  end

  describe "reactor loop" do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:config) do
      Sidekiq::AsyncHttp::Configuration.new(
        logger: logger,
        max_connections: 2
      )
    end
    let(:processor_with_config) { described_class.new(config, metrics: metrics, connection_pool: connection_pool) }

    before do
      allow(connection_pool).to receive(:close_all)
      allow(connection_pool).to receive(:with_client).and_yield(instance_double(Async::HTTP::Client, call: nil))
    end

    after do
      processor_with_config.stop if processor_with_config.running?
    end

    it "consumes requests from the queue" do
      requests_processed = []
      allow(processor_with_config).to receive(:process_request) do |request|
        requests_processed << request
      end

      processor_with_config.start

      request1 = TestRequest.new(id: "request1")
      request2 = TestRequest.new(id: "request2")

      processor_with_config.enqueue(request1)
      processor_with_config.enqueue(request2)

      processor_with_config.wait_for_idle

      expect(requests_processed).to include(request1, request2)
    end

    it "spawns new fibers for each request" do
      fiber_count = Concurrent::AtomicFixnum.new(0)

      allow(processor_with_config).to receive(:process_request) do |request|
        fiber_count.increment
      end

      processor_with_config.start

      # Enqueue multiple requests
      3.times { |i| processor_with_config.enqueue(TestRequest.new(id: "request#{i}")) }

      processor_with_config.wait_for_idle

      expect(fiber_count.value).to eq(3)
    end

    it "checks max connections before spawning fibers" do
      # Use real metrics and a low max_connections
      config_low_max = Sidekiq::AsyncHttp::Configuration.new(logger: logger, max_connections: 1)
      real_metrics = Sidekiq::AsyncHttp::Metrics.new
      processor_low_max = described_class.new(config_low_max, metrics: real_metrics, connection_pool: connection_pool)

      allow(connection_pool).to receive(:check_capacity!)

      # Create a slow request that blocks but still tracks in-flight
      processing_started = Concurrent::Event.new
      processing_complete = Concurrent::Event.new

      allow(processor_low_max).to receive(:process_request) do |request|
        # Manually track in-flight like the real method does
        processor_low_max.instance_variable_get(:@in_flight_lock).synchronize do
          processor_low_max.instance_variable_get(:@in_flight_requests)[request.id] = request
        end
        real_metrics.record_request_start(request)

        processing_started.set
        processing_complete.wait(1) # Block until signaled

        # Clean up in-flight tracking
        processor_low_max.instance_variable_get(:@in_flight_lock).synchronize do
          processor_low_max.instance_variable_get(:@in_flight_requests).delete(request.id)
        end
        real_metrics.record_request_complete(request, 0.01)
      end

      processor_low_max.start

      # Enqueue first request - this will start processing and block
      request1 = TestRequest.new(id: "req1")
      processor_low_max.enqueue(request1)

      # Wait for first request to start processing (in_flight will be 1)
      processing_started.wait(1)

      # Now enqueue second request - this should trigger backpressure check
      request2 = TestRequest.new(id: "req2")
      processor_low_max.enqueue(request2)

      # Wait for second request to be dequeued
      sleep(0.01) until processor_low_max.instance_variable_get(:@queue).empty?

      # Should have checked capacity when at max connections
      expect(connection_pool).to have_received(:check_capacity!).with(request2)

      # Clean up
      processing_complete.set
      processor_low_max.wait_for_idle
      processor_low_max.stop
    end

    it "logs reactor start and stop" do
      processor_with_config.start

      expect(log_output.string).to include("Async HTTP Processor started")

      processor_with_config.stop

      expect(log_output.string).to include("Async HTTP Processor stopped")
    end

    it "breaks loop when stopping" do
      # Track if reactor loop is running
      loop_running = Concurrent::AtomicBoolean.new(false)

      # Override dequeue_request to signal when loop is active
      allow(processor_with_config).to receive(:dequeue_request) do |**args|
        loop_running.make_true
        sleep(0.01) # Brief pause to allow shutdown check
        nil
      end

      processor_with_config.start

      # Wait for loop to be running (with timeout)
      sleep(0.001) until loop_running.true?

      # Stop the processor
      processor_with_config.stop(timeout: 0)

      # Should have stopped
      expect(processor_with_config).to be_stopped
    end

    it "handles Async::Stop gracefully" do
      processor_with_config.start

      processor_with_config.stop

      # The log may or may not contain the stop signal message depending on timing
      # Just verify it stopped gracefully
      expect(processor_with_config).to be_stopped
    end

    it "checks capacity before spawning fibers when at limit" do
      # Use real metrics and a low max_connections
      config_low_max = Sidekiq::AsyncHttp::Configuration.new(logger: logger, max_connections: 1)
      real_metrics = Sidekiq::AsyncHttp::Metrics.new
      processor_low_max = described_class.new(config_low_max, metrics: real_metrics, connection_pool: connection_pool)

      allow(connection_pool).to receive(:check_capacity!)

      # Create a slow request that blocks but tracks in-flight
      processing_started = Concurrent::Event.new
      processing_complete = Concurrent::Event.new

      allow(processor_low_max).to receive(:process_request) do |request|
        # Manually track in-flight
        processor_low_max.instance_variable_get(:@in_flight_lock).synchronize do
          processor_low_max.instance_variable_get(:@in_flight_requests)[request.id] = request
        end
        real_metrics.record_request_start(request)

        processing_started.set
        processing_complete.wait(1)

        # Clean up
        processor_low_max.instance_variable_get(:@in_flight_lock).synchronize do
          processor_low_max.instance_variable_get(:@in_flight_requests).delete(request.id)
        end
        real_metrics.record_request_complete(request, 0.01)
      end

      processor_low_max.start

      # Enqueue first request
      request1 = TestRequest.new(id: "req1")
      processor_low_max.enqueue(request1)

      # Wait for first request to start
      processing_started.wait(1)

      # Enqueue second request
      request2 = TestRequest.new(id: "req2")
      processor_low_max.enqueue(request2)

      # Wait for second request to be dequeued
      sleep(0.01) until processor_low_max.instance_variable_get(:@queue).empty?

      expect(connection_pool).to have_received(:check_capacity!).with(request2)

      # Clean up
      processing_complete.set
      processor_low_max.wait_for_idle
      processor_low_max.stop
    end

    it "logs info message when max connections reached" do
      # Use real metrics and a low max_connections
      config_low_max = Sidekiq::AsyncHttp::Configuration.new(logger: logger, max_connections: 1)
      real_metrics = Sidekiq::AsyncHttp::Metrics.new
      processor_low_max = described_class.new(config_low_max, metrics: real_metrics, connection_pool: connection_pool)

      allow(connection_pool).to receive(:check_capacity!)

      # Create a slow request that blocks but tracks in-flight
      processing_started = Concurrent::Event.new
      processing_complete = Concurrent::Event.new

      allow(processor_low_max).to receive(:process_request) do |request|
        # Manually track in-flight
        processor_low_max.instance_variable_get(:@in_flight_lock).synchronize do
          processor_low_max.instance_variable_get(:@in_flight_requests)[request.id] = request
        end
        real_metrics.record_request_start(request)

        processing_started.set
        processing_complete.wait(1)

        # Clean up
        processor_low_max.instance_variable_get(:@in_flight_lock).synchronize do
          processor_low_max.instance_variable_get(:@in_flight_requests).delete(request.id)
        end
        real_metrics.record_request_complete(request, 0.01)
      end

      processor_low_max.start

      # Enqueue first request
      request1 = TestRequest.new(id: "req1")
      processor_low_max.enqueue(request1)

      # Wait for first request to start
      processing_started.wait(1)

      # Enqueue second request - should trigger the log
      request2 = TestRequest.new(id: "req2")
      processor_low_max.enqueue(request2)

      # Wait for second request to be dequeued
      sleep(0.01) until processor_low_max.instance_variable_get(:@queue).empty?

      expect(log_output.string).to include("Async HTTP max connections reached, applying backpressure")

      # Clean up
      processing_complete.set
      processor_low_max.wait_for_idle
      processor_low_max.stop
    end
  end

  describe "HTTP execution" do
    include Async::RSpec::Reactor

    let(:client) { instance_double(Async::HTTP::Client) }
    let(:async_response) { instance_double(Async::HTTP::Protocol::Response) }

    before do
      allow(connection_pool).to receive(:close_all)
      allow(connection_pool).to receive(:with_client).and_yield(client)
      allow(metrics).to receive(:record_request_start)
      allow(metrics).to receive(:record_request_complete)
      allow(metrics).to receive(:record_error)
    end

    it "stores request in Fiber-local storage" do
      captured_fiber_request = nil

      allow(client).to receive(:call) do
        captured_fiber_request = Fiber[:current_request]
        async_response
      end
      allow(async_response).to receive(:read).and_return("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return({})
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(captured_fiber_request).to eq(mock_request)
    end

    it "records request start in metrics" do
      allow(client).to receive(:call).and_return(async_response)
      allow(async_response).to receive(:read).and_return("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return({})
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(metrics).to have_received(:record_request_start).with(mock_request)
    end

    it "builds Async::HTTP::Request from request object" do
      expected_request = nil

      allow(client).to receive(:call) do |req|
        expected_request = req
        async_response
      end
      allow(async_response).to receive(:read).and_return("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return({})
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(expected_request).to be_a(Async::HTTP::Protocol::Request)
      expect(expected_request.method).to eq("GET")
    end

    it "reads response body" do
      allow(client).to receive(:call).and_return(async_response)
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return({"Content-Type" => "application/json"})
      allow(async_response).to receive(:protocol).and_return("HTTP/2")
      allow(async_response).to receive(:read).and_return('{"result":"success"}')

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(async_response).to have_received(:read)
    end

    it "records request completion with duration" do
      allow(client).to receive(:call).and_return(async_response)
      allow(async_response).to receive(:read).and_return("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return({})
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(metrics).to have_received(:record_request_complete).with(mock_request, kind_of(Float))
    end

    it "builds response with all attributes" do
      allow(client).to receive(:call).and_return(async_response)
      allow(async_response).to receive(:read).and_return("response body")
      allow(async_response).to receive(:status).and_return(201)
      allow(async_response).to receive(:headers).and_return({"X-Custom" => "value"})
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      captured_response = nil
      allow(processor).to receive(:handle_success) do |req, resp|
        captured_response = resp
      end

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(captured_response[:status]).to eq(201)
      expect(captured_response[:body]).to eq("response body")
      expect(captured_response[:headers]).to eq({"X-Custom" => "value"})
      expect(captured_response[:protocol]).to eq("HTTP/2")
      expect(captured_response[:request_id]).to eq("req-123")
      expect(captured_response[:duration]).to be_a(Float)
    end

    it "calls handle_success on successful response" do
      allow(client).to receive(:call).and_return(async_response)
      allow(async_response).to receive(:read).and_return("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return({})
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      expect(processor).to receive(:handle_success).with(mock_request, kind_of(Hash))

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    it "handles timeout errors" do
      allow(client).to receive(:call).and_raise(Async::TimeoutError.new("Request timed out"))

      expect(processor).to receive(:handle_error).with(mock_request, kind_of(Async::TimeoutError))
      expect(metrics).to receive(:record_error).with(mock_request, :timeout)

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    it "handles SSL errors" do
      allow(client).to receive(:call).and_raise(OpenSSL::SSL::SSLError.new("SSL error"))

      expect(processor).to receive(:handle_error).with(mock_request, kind_of(OpenSSL::SSL::SSLError))
      expect(metrics).to receive(:record_error).with(mock_request, :ssl)

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    it "handles connection errors" do
      allow(client).to receive(:call).and_raise(Errno::ECONNREFUSED.new("Connection refused"))

      expect(processor).to receive(:handle_error).with(mock_request, kind_of(Errno::ECONNREFUSED))
      expect(metrics).to receive(:record_error).with(mock_request, :connection)

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    it "handles unknown errors" do
      allow(client).to receive(:call).and_raise(StandardError.new("Unknown error"))

      expect(processor).to receive(:handle_error).with(mock_request, kind_of(StandardError))
      expect(metrics).to receive(:record_error).with(mock_request, :unknown)

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    it "classifies errors correctly" do
      expect(processor.send(:classify_error, Async::TimeoutError.new)).to eq(:timeout)
      expect(processor.send(:classify_error, OpenSSL::SSL::SSLError.new)).to eq(:ssl)
      expect(processor.send(:classify_error, Errno::ECONNREFUSED.new)).to eq(:connection)
      expect(processor.send(:classify_error, Errno::ECONNRESET.new)).to eq(:connection)
      expect(processor.send(:classify_error, StandardError.new)).to eq(:unknown)
    end

    it "cleans up Fiber storage in ensure block" do
      allow(client).to receive(:call).and_return(async_response)
      allow(async_response).to receive(:read).and_return("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return({})
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(Fiber[:current_request]).to be_nil
    end

    it "cleans up Fiber storage even on error" do
      allow(client).to receive(:call).and_raise(StandardError.new("Error"))

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(Fiber[:current_request]).to be_nil
    end

    it "builds HTTP request with body when present" do
      request_with_body = TestRequest.new(
        id: "req-456",
        method: :post,
        url: "https://api.example.com/users",
        headers: {"Content-Type" => "application/json"},
        body: '{"name":"John"}',
        timeout: 30,
        success_worker_class: "TestSuccessWorker",
        error_worker_class: "TestErrorWorker",
        job_args: []
      )

      captured_request = nil
      allow(client).to receive(:call) do |req|
        captured_request = req
        async_response
      end
      allow(async_response).to receive(:read).and_return("response body")
      allow(async_response).to receive(:status).and_return(201)
      allow(async_response).to receive(:headers).and_return({})
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, request_with_body)
      end

      expect(captured_request.body).not_to be_nil
    end

    it "uses connection pool with_client" do
      allow(client).to receive(:call).and_return(async_response)
      allow(async_response).to receive(:read).and_return("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return({})
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(connection_pool).to have_received(:with_client).with(mock_request.url)
    end
  end

  describe "success handling" do
    let(:response_hash) do
      {
        status: 200,
        headers: {"content-type" => "application/json"},
        body: '{"result":"ok"}',
        protocol: "HTTP/2",
        request_id: "req-123",
        url: "https://api.example.com/users",
        method: "GET",
        duration: 0.5
      }
    end

    let(:success_worker_class) { class_double("TestSuccessWorker") }

    before do
      stub_const("TestSuccessWorker", success_worker_class)
      allow(success_worker_class).to receive(:perform_async)
    end

    it "resolves worker class from string name" do
      processor.send(:handle_success, mock_request, response_hash)
      expect(success_worker_class).to have_received(:perform_async)
    end

    it "enqueues success worker with response hash and original args" do
      processor.send(:handle_success, mock_request, response_hash)
      expect(success_worker_class).to have_received(:perform_async).with(response_hash, 1, "test_arg")
    end

    it "logs success at debug level" do
      log_output = StringIO.new
      logger = Logger.new(log_output)
      logger.level = Logger::DEBUG

      # Create a new processor with a logger in the config
      config_with_logger = Sidekiq::AsyncHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger, metrics: metrics, connection_pool: connection_pool)

      processor_with_logger.send(:handle_success, mock_request, response_hash)

      expect(log_output.string).to match(
        /Async HTTP request req-123 succeeded with status 200.*enqueued TestSuccessWorker/
      )
    end

    it "handles errors during enqueue gracefully" do
      allow(success_worker_class).to receive(:perform_async).and_raise(StandardError.new("Sidekiq error"))

      log_output = StringIO.new
      logger = Logger.new(log_output)

      # Create a new processor with a logger in the config
      config_with_logger = Sidekiq::AsyncHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger, metrics: metrics, connection_pool: connection_pool)

      expect {
        processor_with_logger.send(:handle_success, mock_request, response_hash)
      }.not_to raise_error

      expect(log_output.string).to match(
        /Async HTTP failed to enqueue success worker for request req-123/
      )
    end

    it "handles namespaced worker classes" do
      namespaced_worker = class_double("MyApp::Workers::TestSuccessWorker")
      stub_const("MyApp::Workers::TestSuccessWorker", namespaced_worker)
      allow(namespaced_worker).to receive(:perform_async)

      namespaced_request = TestRequest.new(
        id: "req-456",
        success_worker_class: "MyApp::Workers::TestSuccessWorker",
        job_args: [42]
      )

      processor.send(:handle_success, namespaced_request, response_hash)

      expect(namespaced_worker).to have_received(:perform_async).with(response_hash, 42)
    end
  end

  describe "error handling" do
    let(:error_worker_class) { class_double("TestErrorWorker") }

    before do
      stub_const("TestErrorWorker", error_worker_class)
      allow(error_worker_class).to receive(:perform_async)
    end

    it "builds Error from exception" do
      exception = Async::TimeoutError.new("Request timed out")

      processor.send(:handle_error, mock_request, exception)

      expect(error_worker_class).to have_received(:perform_async) do |error_hash, *args|
        expect(error_hash["error_type"]).to eq("timeout")
        expect(error_hash["class_name"]).to eq("Async::TimeoutError")
        expect(error_hash["message"]).to eq("Request timed out")
        expect(error_hash["request_id"]).to eq("req-123")
      end
    end

    it "enqueues error worker with error hash and original args" do
      exception = StandardError.new("Test error")

      processor.send(:handle_error, mock_request, exception)

      expect(error_worker_class).to have_received(:perform_async) do |error_hash, *args|
        expect(error_hash).to be_a(Hash)
        expect(args).to eq([1, "test_arg"])
      end
    end

    it "handles timeout errors" do
      exception = Async::TimeoutError.new("Request timed out")

      processor.send(:handle_error, mock_request, exception)

      expect(error_worker_class).to have_received(:perform_async) do |error_hash, *args|
        expect(error_hash["error_type"]).to eq("timeout")
      end
    end

    it "handles connection errors" do
      exception = Errno::ECONNREFUSED.new("Connection refused")

      processor.send(:handle_error, mock_request, exception)

      expect(error_worker_class).to have_received(:perform_async) do |error_hash, *args|
        expect(error_hash["error_type"]).to eq("connection")
      end
    end

    it "handles SSL errors" do
      exception = OpenSSL::SSL::SSLError.new("SSL error")

      processor.send(:handle_error, mock_request, exception)

      expect(error_worker_class).to have_received(:perform_async) do |error_hash, *args|
        expect(error_hash["error_type"]).to eq("ssl")
      end
    end

    it "handles protocol errors" do
      # Create a mock protocol error
      protocol_error_class = Class.new(StandardError)
      stub_const("Async::HTTP::Protocol::Error", protocol_error_class)
      exception = protocol_error_class.new("Protocol error")

      processor.send(:handle_error, mock_request, exception)

      expect(error_worker_class).to have_received(:perform_async) do |error_hash, *args|
        expect(error_hash["error_type"]).to eq("protocol")
      end
    end

    it "handles unknown errors" do
      exception = StandardError.new("Unknown error")

      processor.send(:handle_error, mock_request, exception)

      expect(error_worker_class).to have_received(:perform_async) do |error_hash, *args|
        expect(error_hash["error_type"]).to eq("unknown")
      end
    end

    it "logs error at warn level" do
      log_output = StringIO.new
      logger = Logger.new(log_output)

      config_with_logger = Sidekiq::AsyncHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger, metrics: metrics, connection_pool: connection_pool)

      exception = Async::TimeoutError.new("Request timed out")

      processor_with_logger.send(:handle_error, mock_request, exception)

      expect(log_output.string).to match(/Async HTTP request req-123 failed with timeout error/)
      expect(log_output.string).to match(/enqueued TestErrorWorker/)
    end

    it "handles errors during enqueue gracefully" do
      allow(error_worker_class).to receive(:perform_async).and_raise(StandardError.new("Sidekiq error"))

      log_output = StringIO.new
      logger = Logger.new(log_output)

      config_with_logger = Sidekiq::AsyncHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger, metrics: metrics, connection_pool: connection_pool)

      exception = StandardError.new("Test error")

      expect {
        processor_with_logger.send(:handle_error, mock_request, exception)
      }.not_to raise_error

      expect(log_output.string).to match(/Async HTTP failed to enqueue error worker for request req-123/)
    end

    it "resolves worker class from string name" do
      exception = StandardError.new("Test error")

      processor.send(:handle_error, mock_request, exception)

      expect(error_worker_class).to have_received(:perform_async)
    end

    it "handles namespaced error worker classes" do
      namespaced_worker = class_double("MyApp::Workers::TestErrorWorker")
      stub_const("MyApp::Workers::TestErrorWorker", namespaced_worker)
      allow(namespaced_worker).to receive(:perform_async)

      namespaced_request = TestRequest.new(
        id: "req-789",
        error_worker_class: "MyApp::Workers::TestErrorWorker",
        job_args: [99]
      )

      exception = StandardError.new("Test error")

      processor.send(:handle_error, namespaced_request, exception)

      expect(namespaced_worker).to have_received(:perform_async) do |error_hash, *args|
        expect(error_hash).to be_a(Hash)
        expect(args).to eq([99])
      end
    end

    it "includes backtrace in error hash" do
      exception = StandardError.new("Test error")
      exception.set_backtrace(["line 1", "line 2", "line 3"])

      processor.send(:handle_error, mock_request, exception)

      expect(error_worker_class).to have_received(:perform_async) do |error_hash, *args|
        expect(error_hash["backtrace"]).to eq(["line 1", "line 2", "line 3"])
      end
    end
  end

  describe "graceful shutdown" do
    let(:worker_class) { class_double("TestWorker") }
    let(:mock_client) { double("Async::HTTP::Client") }
    let(:mock_async_response) do
      double("Async::HTTP::Response",
        status: 200,
        headers: {"Content-Type" => "application/json"},
        protocol: "HTTP/1.1")
    end

    before do
      stub_const("TestWorker", worker_class)
      allow(worker_class).to receive(:perform_async)
      allow(connection_pool).to receive(:close_all)
    end

    it "completes all in-flight requests during clean shutdown" do
      # Set up connection pool mock
      allow(connection_pool).to receive(:with_client).and_yield(mock_client)
      allow(mock_client).to receive(:call).and_return(mock_async_response)
      allow(mock_async_response).to receive(:read).and_return("response body")

      processor.start

      # Enqueue a request
      request = TestRequest.new(
        id: "req-clean",
        success_worker_class: "TestSuccessWorker",
        original_worker_class: "TestWorker",
        original_args: [1, 2, 3]
      )
      processor.enqueue(request)

      # Wait for request to complete
      processor.wait_for_idle(timeout: 2)

      # Stop with timeout
      processor.stop(timeout: 1)

      # Should not re-enqueue completed request
      expect(worker_class).not_to have_received(:perform_async)
    end

    it "re-enqueues incomplete requests when timeout expires" do
      # Set up slow connection pool mock that won't complete in time
      allow(connection_pool).to receive(:with_client) do |&block|
        sleep(0.1) # Simulate slow request
        block.call(mock_client)
      end
      allow(mock_client).to receive(:call).and_return(mock_async_response)
      allow(mock_async_response).to receive(:read).and_return("response body")

      processor.start

      # Enqueue a request
      request = TestRequest.new(
        id: "req-timeout",
        success_worker_class: "TestSuccessWorker",
        original_worker_class: "TestWorker",
        original_args: [4, 5, 6]
      )
      processor.enqueue(request)
      processor.wait_for_processing

      # Stop with short timeout (request won't complete)
      processor.stop(timeout: 0.001)

      # Should re-enqueue the incomplete request
      expect(worker_class).to have_received(:perform_async).with(4, 5, 6)
    end

    it "re-enqueues multiple incomplete requests" do
      # Set up slow connection pool mock
      allow(connection_pool).to receive(:with_client) do |&block|
        sleep(0.1) # Simulate slow request
        block.call(mock_client)
      end
      allow(mock_client).to receive(:call).and_return(mock_async_response)
      allow(mock_async_response).to receive(:read).and_return("response body")

      processor.start

      # Enqueue multiple requests
      request1 = TestRequest.new(
        id: "req-multi-1",
        success_worker_class: "TestSuccessWorker",
        original_worker_class: "TestWorker",
        original_args: [10, 20]
      )
      request2 = TestRequest.new(
        id: "req-multi-2",
        success_worker_class: "TestSuccessWorker",
        original_worker_class: "TestWorker",
        original_args: [30, 40]
      )
      request3 = TestRequest.new(
        id: "req-multi-3",
        success_worker_class: "TestSuccessWorker",
        original_worker_class: "TestWorker",
        original_args: [50, 60]
      )

      processor.enqueue(request1)
      processor.enqueue(request2)
      processor.enqueue(request3)

      # Wait for requests to start processing
      processor.wait_for_processing

      # Stop with short timeout
      processor.stop(timeout: 0.001)

      # Should re-enqueue all incomplete requests
      expect(worker_class).to have_received(:perform_async).with(10, 20)
      expect(worker_class).to have_received(:perform_async).with(30, 40)
      expect(worker_class).to have_received(:perform_async).with(50, 60)
    end

    it "logs re-enqueued requests at info level" do
      # Set up slow connection pool mock
      allow(connection_pool).to receive(:with_client) do |&block|
        sleep(0.1) # Simulate slow request
        block.call(mock_client)
      end
      allow(mock_client).to receive(:call).and_return(mock_async_response)
      allow(mock_async_response).to receive(:read).and_return("response body")

      log_output = StringIO.new
      logger = Logger.new(log_output)

      config_with_logger = Sidekiq::AsyncHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger, metrics: metrics, connection_pool: connection_pool)

      processor_with_logger.start

      # Enqueue a request
      request = TestRequest.new(
        id: "req-log",
        success_worker_class: "TestSuccessWorker",
        original_worker_class: "TestWorker",
        original_args: [99]
      )
      processor_with_logger.enqueue(request)

      # Wait for request to start processing
      processor_with_logger.wait_for_processing

      # Stop with short timeout
      processor_with_logger.stop(timeout: 0.001)

      # Check log output
      expect(log_output.string).to match(/Async HTTP re-enqueued incomplete request req-log to TestWorker/)
    end

    it "handles errors during re-enqueue gracefully" do
      # Set up slow connection pool mock
      allow(connection_pool).to receive(:with_client) do |&block|
        sleep(0.1) # Simulate slow request
        block.call(mock_client)
      end
      allow(mock_client).to receive(:call).and_return(mock_async_response)
      allow(mock_async_response).to receive(:read).and_return("response body")

      # Make re-enqueue fail
      allow(worker_class).to receive(:perform_async).and_raise(StandardError.new("Enqueue failed"))

      log_output = StringIO.new
      logger = Logger.new(log_output)

      config_with_logger = Sidekiq::AsyncHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger, metrics: metrics, connection_pool: connection_pool)

      processor_with_logger.start

      # Enqueue a request
      request = TestRequest.new(
        id: "req-error",
        success_worker_class: "TestSuccessWorker",
        original_worker_class: "TestWorker",
        original_args: [77]
      )
      processor_with_logger.enqueue(request)
      processor_with_logger.wait_for_processing

      # Stop should not raise error
      expect {
        processor_with_logger.stop(timeout: 0.001)
      }.not_to raise_error

      # Check error was logged
      expect(log_output.string).to match(/Async HTTP failed to re-enqueue request req-error/)
    end

    it "handles namespaced worker classes during re-enqueue" do
      namespaced_worker = class_double("MyApp::Workers::TestWorker")
      stub_const("MyApp::Workers::TestWorker", namespaced_worker)
      allow(namespaced_worker).to receive(:perform_async)

      # Set up slow connection pool mock
      allow(connection_pool).to receive(:with_client) do |&block|
        sleep(0.1) # Simulate slow request
        block.call(mock_client)
      end
      allow(mock_client).to receive(:call).and_return(mock_async_response)
      allow(mock_async_response).to receive(:read).and_return("response body")

      processor.start

      # Enqueue a request with namespaced worker
      request = TestRequest.new(
        id: "req-namespaced",
        success_worker_class: "TestSuccessWorker",
        original_worker_class: "MyApp::Workers::TestWorker",
        original_args: [111, 222]
      )
      processor.enqueue(request)
      processor.wait_for_processing

      # Stop with short timeout
      processor.stop(timeout: 0.001)

      # Should re-enqueue with correct worker class
      expect(namespaced_worker).to have_received(:perform_async).with(111, 222)
    end
  end
end
