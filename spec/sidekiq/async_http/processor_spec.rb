# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Processor do
  let(:config) { Sidekiq::AsyncHttp.configuration }
  let(:processor) { described_class.new(config) }
  let(:metrics) { processor.metrics }

  # Helper to create request tasks for testing
  def create_request_task(
    method: :get,
    url: "https://api.example.com/users",
    headers: {},
    body: nil,
    timeout: 30,
    connect_timeout: nil,
    worker_class: "TestWorkers::Worker",
    jid: nil,
    job_args: [],
    completion_worker: "TestWorkers::CompletionWorker",
    error_worker: "TestWorkers::ErrorWorker"
  )
    request = Sidekiq::AsyncHttp::Request.new(
      method: method,
      url: url,
      headers: headers,
      body: body,
      timeout: timeout,
      connect_timeout: connect_timeout
    )
    Sidekiq::AsyncHttp::RequestTask.new(
      request: request,
      sidekiq_job: {"class" => worker_class, "jid" => jid || SecureRandom.uuid, "args" => job_args},
      completion_worker: completion_worker,
      error_worker: error_worker
    )
  end

  # Mock request task object matching the expected structure
  let(:mock_request) do
    create_request_task(
      headers: {"Accept" => "application/json"},
      jid: "jid-123",
      job_args: [1, "test_arg"]
    )
  end

  describe ".new" do
    it "initializes with provided config and metrics" do
      expect(processor.config).to eq(config)
      expect(processor.metrics).to eq(metrics)
    end

    it "initializes with defaults if not provided" do
      processor = described_class.new
      expect(processor.config).to be_a(Sidekiq::AsyncHttp::Configuration)
      expect(processor.metrics).to be_a(Sidekiq::AsyncHttp::Metrics)
    end

    it "starts in stopped state" do
      expect(processor).to be_stopped
      expect(processor.state).to eq(:stopped)
    end
  end

  describe "#start" do
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

      it "signals the shutdown barrier" do
        barrier = processor.instance_variable_get(:@shutdown_barrier)
        processor.stop
        expect(barrier).to be_set
      end

      context "with timeout" do
        it "waits for in-flight requests to complete" do
          allow(processor).to receive(:idle?).and_return(false, false, false, true)

          start_time = Time.now
          processor.stop(timeout: 0.2)
          elapsed = Time.now - start_time

          # Should wait but not exceed timeout significantly
          expect(elapsed).to be < 1.0
        end

        it "does not wait longer than timeout" do
          allow(processor).to receive(:idle?).and_return(false)

          start_time = Time.now
          processor.stop(timeout: 0.2)
          elapsed = Time.now - start_time

          # Should stop around timeout
          expect(elapsed).to be_between(0.15, 0.5)
        end

        it "stops immediately if timeout is nil" do
          allow(processor).to receive(:idle?).and_return(false)

          start_time = Time.now
          processor.stop(timeout: nil)
          elapsed = Time.now - start_time

          # Should not wait for requests
          expect(elapsed).to be < 0.2
        end

        it "stops immediately if timeout is zero" do
          allow(processor).to receive(:idle?).and_return(false)

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
    let(:request) { create_request_task }

    after do
      processor.stop if processor.running? || processor.draining?
    end

    context "when running" do
      before do
        stub_request(:get, "https://api.example.com/users")
          .to_return(status: 200, body: "response", headers: {})
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

      it "raises an error" do
        expect { processor.enqueue(request) }.to raise_error(Sidekiq::AsyncHttp::NotRunningError, /Cannot enqueue request: processor is draining/)
      end
    end

    context "when stopped" do
      it "raises an error" do
        expect { processor.enqueue(request) }.to raise_error(Sidekiq::AsyncHttp::NotRunningError, /Cannot enqueue request: processor is stopped/)
      end
    end

    context "when stopping" do
      before do
        processor.start
        processor.instance_variable_get(:@state).set(:stopping)
      end

      it "raises an error" do
        expect { processor.enqueue(request) }.to raise_error(Sidekiq::AsyncHttp::NotRunningError, /Cannot enqueue request: processor is stopping/)
      end
    end
  end

  describe "state predicates" do
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

    describe "#drained?" do
      it "returns true when draining and idle" do
        processor.start
        processor.drain
        expect(processor).to be_idle
        expect(processor.drained?).to be true
        processor.stop
      end

      it "returns false when draining but not idle" do
        stub_request(:get, "https://api.example.com/users")
          .to_return do
            sleep(0.1) # Delay response to keep request in-flight
            {status: 200, body: "response body", headers: {}}
          end

        processor.start
        processor.enqueue(mock_request)
        processor.wait_for_processing(timeout: 0.5)
        processor.drain

        # Should be draining but not idle (request still in flight)
        expect(processor.draining?).to be true
        expect(processor.drained?).to be false

        processor.stop
      end

      it "returns false when not draining" do
        processor.start
        expect(processor.drained?).to be false
        processor.stop
      end
    end
  end

  describe "state transitions" do
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
    around do |example|
      # Disable WebMock entirely for this test to work around Async fiber limitations
      # WebMock stubs don't reliably propagate to Async fibers due to thread-local storage
      WebMock.reset!
      WebMock.allow_net_connect!

      example.run
    ensure
      WebMock.reset!
      WebMock.disable_net_connect!(allow_localhost: true)
    end

    it "handles concurrent enqueues safely" do
      # Stub the HTTP request - this will be used when the fiber context allows
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: "{}", headers: {"Content-Type" => "application/json"})

      # Mock dequeue_request to prevent processing
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
            request = create_request_task
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

      # Stop processor before restoring WebMock to avoid warnings in cleanup
      processor.stop if processor.running?
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
    let(:processor_with_logger) { described_class.new(config) }

    it "logs errors from the reactor loop" do
      error_logged = Concurrent::AtomicBoolean.new(false)
      # Force an error in the reactor by making dequeue_request raise
      allow(processor_with_logger).to receive(:dequeue_request) do
        error_logged.make_true
        raise StandardError.new("Test error")
      end

      processor_with_logger.start
      processor_with_logger.wait_for_running

      # Wait for the error to be logged
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      until error_logged.true? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Thread.pass
      end

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

    before do
      stub_request(:get, "https://api.example.com/users").to_return(status: 200, body: "response", headers: {})
    end

    it "consumes requests from the queue" do
      requests_processed = []
      signal_queue = Queue.new
      processor = described_class.new(config)
      processor.testing_callback = ->(task) {
        requests_processed << task
        signal_queue << task
      }
      processor.start

      request1 = create_request_task
      request2 = create_request_task

      processor.enqueue(request1)
      processor.enqueue(request2)

      # Wait for both requests to be processed
      2.times { signal_queue.pop }

      expect(requests_processed).to include(request1, request2)
    end

    it "spawns new fibers for each request" do
      fiber_count = Concurrent::AtomicFixnum.new(0)
      signal_queue = Queue.new
      processor = described_class.new(config)
      processor.testing_callback = ->(task) {
        fiber_count.increment
        signal_queue << task
      }
      processor.start

      # Enqueue multiple requests
      3.times { |i| processor.enqueue(create_request_task) }

      # Wait for all 3 to complete
      3.times { signal_queue.pop }

      expect(fiber_count.value).to eq(3)
    end

    it "logs reactor start and stop" do
      processor.start

      expect(log_output.string).to include("[Sidekiq::AsyncHttp] Processor started")

      processor.stop

      expect(log_output.string).to include("[Sidekiq::AsyncHttp] Processor stopped")
    end

    it "breaks loop when stopping" do
      # Track if reactor loop is running
      loop_running = Concurrent::AtomicBoolean.new(false)

      # Override dequeue_request to signal when loop is active
      allow(processor).to receive(:dequeue_request) do |**args|
        loop_running.make_true
        sleep(0.01) # Brief pause to allow shutdown check
        nil
      end

      processor.start
      processor.wait_for_running

      # Stop the processor
      processor.stop(timeout: 0)

      # Should have stopped
      expect(processor).to be_stopped
    end

    it "handles Async::Stop gracefully" do
      processor.start

      processor.stop

      # The log may or may not contain the stop signal message depending on timing
      # Just verify it stopped gracefully
      expect(processor).to be_stopped
    end

    it "checks capacity before spawning fibers when at limit" do
      processor.start
      allow(processor).to receive(:inflight_count).and_return(config.max_connections)
      expect { processor.enqueue(create_request_task) }.to raise_error(Sidekiq::AsyncHttp::MaxCapacityError, /already at max capacity/)
      processor.stop(timeout: 0)
    end
  end

  describe "HTTP execution" do
    include Async::RSpec::Reactor

    let(:client) { instance_double(Async::HTTP::Client) }
    let(:async_response) { instance_double(Async::HTTP::Protocol::Response) }
    let(:response_body) { instance_double(Protocol::HTTP::Body::Buffered) }

    before do
      allow(Async::HTTP::Client).to receive(:new).and_return(client)
      allow(metrics).to receive(:record_request_start)
      allow(metrics).to receive(:record_request_complete)
      allow(metrics).to receive(:record_error)
    end

    # Helper to create a headers double that supports [] access
    def stub_headers(headers_hash = {})
      headers_double = double("Headers")
      allow(headers_double).to receive(:[]) do |key|
        headers_hash[key]
      end
      allow(headers_double).to receive(:to_h).and_return(headers_hash)
      headers_double
    end

    # Helper to stub async_response with a body
    def stub_async_response_body(body_content)
      allow(async_response).to receive(:body).and_return(response_body)
      # Support both .each (new) and .join (old) for compatibility
      allow(response_body).to receive(:each).and_yield(body_content)
      allow(response_body).to receive(:join).and_return(body_content)
      allow(async_response).to receive(:close)
    end

    it "records request start in metrics" do
      allow(client).to receive(:call).and_return(async_response)
      stub_async_response_body("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(metrics).to have_received(:record_request_start)
    end

    it "builds Async::HTTP::Request from request object" do
      expected_request = nil

      allow(client).to receive(:call) do |req|
        expected_request = req
        async_response
      end
      stub_async_response_body("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({}))
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
      allow(async_response).to receive(:headers).and_return(stub_headers({"Content-Type" => "application/json"}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")
      stub_async_response_body('{"result":"success"}')

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(response_body).to have_received(:each)
    end

    it "records request completion with duration" do
      allow(client).to receive(:call).and_return(async_response)
      stub_async_response_body("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(metrics).to have_received(:record_request_complete).with(kind_of(Float))
    end

    it "builds response with all attributes" do
      allow(client).to receive(:call).and_return(async_response)
      stub_async_response_body("response body")
      allow(async_response).to receive(:status).and_return(201)
      allow(async_response).to receive(:headers).and_return(stub_headers({"X-Custom" => "value"}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      captured_response = nil
      allow(processor).to receive(:handle_success) do |req, resp|
        captured_response = resp
      end

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(captured_response.status).to eq(201)
      expect(captured_response.body).to eq("response body")
      expect(captured_response.headers["X-Custom"]).to eq("value")
      expect(captured_response.protocol).to eq("HTTP/2")
      expect(captured_response.request_id).to eq(mock_request.id)
      expect(captured_response.duration).to be_a(Float)
    end

    it "calls handle_success on successful response" do
      allow(client).to receive(:call).and_return(async_response)
      stub_async_response_body("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      expect(processor).to receive(:handle_success).with(mock_request, kind_of(Sidekiq::AsyncHttp::Response))

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    # Parameterized error handling tests
    [
      {error_class: Async::TimeoutError, error_message: "Request timed out", error_type: :timeout},
      {error_class: OpenSSL::SSL::SSLError, error_message: "SSL error", error_type: :ssl},
      {error_class: Errno::ECONNREFUSED, error_message: "Connection refused", error_type: :connection},
      {error_class: StandardError, error_message: "Unknown error", error_type: :unknown}
    ].each do |test_case|
      it "handles #{test_case[:error_type]} errors" do
        allow(client).to receive(:call).and_raise(test_case[:error_class].new(test_case[:error_message]))

        expect(processor).to receive(:handle_error).with(mock_request, kind_of(test_case[:error_class]))
        expect(metrics).to receive(:record_error).with(test_case[:error_type])

        Async do
          processor.send(:process_request, mock_request)
        end
      end
    end

    it "classifies errors correctly" do
      expect(processor.send(:classify_error, Async::TimeoutError.new)).to eq(:timeout)
      expect(processor.send(:classify_error, Sidekiq::AsyncHttp::ResponseTooLargeError.new)).to eq(:response_too_large)
      expect(processor.send(:classify_error, OpenSSL::SSL::SSLError.new)).to eq(:ssl)
      expect(processor.send(:classify_error, Errno::ECONNREFUSED.new)).to eq(:connection)
      expect(processor.send(:classify_error, Errno::ECONNRESET.new)).to eq(:connection)
      expect(processor.send(:classify_error, StandardError.new)).to eq(:unknown)
    end

    it "raises ResponseTooLargeError when content-length exceeds max" do
      allow(client).to receive(:call).and_return(async_response)
      allow(async_response).to receive(:body).and_return(response_body)
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({"content-length" => "20000000"}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      expect(processor).to receive(:handle_error).with(mock_request, kind_of(Sidekiq::AsyncHttp::ResponseTooLargeError))
      expect(metrics).to receive(:record_error).with(:response_too_large)

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    it "raises ResponseTooLargeError when body size exceeds max during read" do
      allow(client).to receive(:call).and_return(async_response)
      allow(async_response).to receive(:body).and_return(response_body)
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      # Simulate large body chunks that exceed max_response_size
      large_chunk = "x" * 6_000_000
      allow(response_body).to receive(:each).and_yield(large_chunk).and_yield(large_chunk)

      expect(processor).to receive(:handle_error).with(mock_request, kind_of(Sidekiq::AsyncHttp::ResponseTooLargeError))
      expect(metrics).to receive(:record_error).with(:response_too_large)

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    it "handles ResponseTooLargeError correctly" do
      allow(client).to receive(:call).and_return(async_response)
      allow(async_response).to receive(:body).and_return(response_body)
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({"content-length" => "20000000"}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      expect(processor).to receive(:handle_error).with(mock_request, kind_of(Sidekiq::AsyncHttp::ResponseTooLargeError))
      expect(metrics).to receive(:record_error).with(:response_too_large)

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    it "cleans up Fiber storage in ensure block" do
      allow(client).to receive(:call).and_return(async_response)
      stub_async_response_body("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({}))
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
      request_with_body = create_request_task(
        method: :post,
        url: "https://api.example.com/users",
        headers: {"Content-Type" => "application/json"},
        body: '{"name":"John"}',
        timeout: 30
      )

      captured_request = nil
      allow(client).to receive(:call) do |req|
        captured_request = req
        async_response
      end
      stub_async_response_body("response body")
      allow(async_response).to receive(:status).and_return(201)
      allow(async_response).to receive(:headers).and_return(stub_headers({}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, request_with_body)
      end

      expect(captured_request.body).not_to be_nil
    end

    it "uses connection pool with_client" do
      allow(client).to receive(:call).and_return(async_response)
      stub_async_response_body("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    it "uses idle_connection_timeout from configuration" do
      endpoint = nil
      allow(Async::HTTP::Endpoint).to receive(:parse) do |url, options|
        endpoint = double("Endpoint", url: url)
        expect(options[:idle_timeout]).to eq(config.idle_connection_timeout)
        endpoint
      end
      allow(Async::HTTP::Client).to receive(:new).with(endpoint).and_return(client)
      allow(client).to receive(:call).and_return(async_response)
      stub_async_response_body("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(Async::HTTP::Endpoint).to have_received(:parse)
    end

    it "uses connect_timeout from request when provided" do
      request_with_timeout = create_request_task(
        connect_timeout: 5.0
      )

      endpoint = nil
      allow(Async::HTTP::Endpoint).to receive(:parse) do |url, options|
        endpoint = double("Endpoint", url: url)
        expect(options[:connect_timeout]).to eq(5.0)
        endpoint
      end
      allow(Async::HTTP::Client).to receive(:new).with(endpoint).and_return(client)
      allow(client).to receive(:call).and_return(async_response)
      stub_async_response_body("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      Async do
        processor.send(:process_request, request_with_timeout)
      end

      expect(Async::HTTP::Endpoint).to have_received(:parse)
    end

    it "uses default_request_timeout from configuration when request timeout is nil" do
      # Create request with nil timeout to use default
      request_without_timeout = create_request_task(timeout: nil)

      allow(client).to receive(:call).and_return(async_response)
      stub_async_response_body("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      # Mock the timeout wrapper to capture the timeout value
      timeout_value = nil
      allow(Async::Task).to receive(:current).and_return(double("Task").tap do |task|
        allow(task).to receive(:with_timeout) do |timeout, &block|
          timeout_value = timeout
          block.call
        end
      end)

      Async do
        processor.send(:process_request, request_without_timeout)
      end

      expect(timeout_value).to eq(config.default_request_timeout)
    end

    it "uses request timeout when provided" do
      request_with_timeout = create_request_task(
        timeout: 45.0
      )

      allow(client).to receive(:call).and_return(async_response)
      stub_async_response_body("response body")
      allow(async_response).to receive(:status).and_return(200)
      allow(async_response).to receive(:headers).and_return(stub_headers({}))
      allow(async_response).to receive(:protocol).and_return("HTTP/2")

      # Mock the timeout wrapper to capture the timeout value
      timeout_value = nil
      allow(Async::Task).to receive(:current).and_return(double("Task").tap do |task|
        allow(task).to receive(:with_timeout) do |timeout, &block|
          timeout_value = timeout
          block.call
        end
      end)

      Async do
        processor.send(:process_request, request_with_timeout)
      end

      expect(timeout_value).to eq(45.0)
    end
  end

  describe "success handling" do
    let(:response_hash) do
      {
        "status" => 200,
        "headers" => {"content-type" => "application/json"},
        "body" => {"encoding" => "text", "value" => '{"result":"ok"}'},
        "protocol" => "HTTP/2",
        "request_id" => "req-123",
        "url" => "https://api.example.com/users",
        "method" => "GET",
        "duration" => 0.5
      }
    end

    let(:response) { Sidekiq::AsyncHttp::Response.from_h(response_hash) }

    before do
      processor.start
    end

    after do
      processor.stop
    end

    it "resolves worker class from string name" do
      processor.send(:handle_success, mock_request, response)
      expect(TestWorkers::CompletionWorker.jobs.size).to eq(1)
    end

    it "enqueues success worker with response hash and original args tagged as a completion continuation" do
      processor.send(:handle_success, mock_request, response)
      expect(TestWorkers::CompletionWorker.jobs.size).to eq(1)
      job = TestWorkers::CompletionWorker.jobs.last
      job_args = job["args"]
      expect(job_args[0]).to be_a(Hash)
      expect(job_args[0]["status"]).to eq(200)
      expect(job_args[1..]).to eq([1, "test_arg"])
      expect(job["async_http_continuation"]).to eq("completion")
    end

    it "logs success at debug level" do
      log_output = StringIO.new
      logger = Logger.new(log_output)
      logger.level = Logger::DEBUG

      # Create a new processor with a logger in the config
      config_with_logger = Sidekiq::AsyncHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger)
      processor_with_logger.start
      processor_with_logger.send(:handle_success, mock_request, response)
      processor_with_logger.stop

      expect(log_output.string).to match(
        /DEBUG.*\[Sidekiq::AsyncHttp\] Request #{Regexp.escape(mock_request.id)} succeeded with status 200.*enqueued TestWorkers::CompletionWorker/
      )
    end
  end

  describe "error handling" do
    before do
      processor.start
    end

    after do
      processor.stop
    end

    it "builds Error from exception" do
      exception = Async::TimeoutError.new("Request timed out")

      processor.send(:handle_error, mock_request, exception)

      expect(TestWorkers::ErrorWorker.jobs.size).to eq(1)
      error_hash = TestWorkers::ErrorWorker.jobs.last["args"].first
      expect(error_hash["error_type"]).to eq("timeout")
      expect(error_hash["class_name"]).to eq("Async::TimeoutError")
      expect(error_hash["message"]).to eq("Request timed out")
      expect(error_hash["request_id"]).to eq(mock_request.id)
    end

    it "enqueues error worker with error hash and original args tagged as an error continuation" do
      exception = StandardError.new("Test error")

      processor.send(:handle_error, mock_request, exception)

      expect(TestWorkers::ErrorWorker.jobs.size).to eq(1)
      job = TestWorkers::ErrorWorker.jobs.last
      job_args = job["args"]
      expect(job_args.first).to be_a(Hash)
      expect(job_args[1..]).to eq([1, "test_arg"])
      expect(job["async_http_continuation"]).to eq("error")
    end

    it "handles timeout errors" do
      exception = Async::TimeoutError.new("Request timed out")

      processor.send(:handle_error, mock_request, exception)

      expect(TestWorkers::ErrorWorker.jobs.size).to eq(1)
      error_hash = TestWorkers::ErrorWorker.jobs.last["args"].first
      expect(error_hash["error_type"]).to eq("timeout")
    end

    it "handles connection errors" do
      exception = Errno::ECONNREFUSED.new("Connection refused")

      processor.send(:handle_error, mock_request, exception)

      expect(TestWorkers::ErrorWorker.jobs.size).to eq(1)
      error_hash = TestWorkers::ErrorWorker.jobs.last["args"].first
      expect(error_hash["error_type"]).to eq("connection")
    end

    it "handles SSL errors" do
      exception = OpenSSL::SSL::SSLError.new("SSL error")

      processor.send(:handle_error, mock_request, exception)

      expect(TestWorkers::ErrorWorker.jobs.size).to eq(1)
      error_hash = TestWorkers::ErrorWorker.jobs.last["args"].first
      expect(error_hash["error_type"]).to eq("ssl")
    end

    it "handles protocol errors" do
      # Create a mock protocol error
      protocol_error_class = Class.new(StandardError)
      stub_const("Async::HTTP::Protocol::Error", protocol_error_class)
      exception = protocol_error_class.new("Protocol error")

      processor.send(:handle_error, mock_request, exception)

      expect(TestWorkers::ErrorWorker.jobs.size).to eq(1)
      error_hash = TestWorkers::ErrorWorker.jobs.last["args"].first
      expect(error_hash["error_type"]).to eq("protocol")
    end

    it "handles unknown errors" do
      exception = StandardError.new("Unknown error")

      processor.start
      processor.send(:handle_error, mock_request, exception)
      processor.stop

      expect(TestWorkers::ErrorWorker.jobs.size).to eq(1)
      error_hash = TestWorkers::ErrorWorker.jobs.last["args"].first
      expect(error_hash["error_type"]).to eq("unknown")
    end

    it "logs error at warn level" do
      log_output = StringIO.new
      logger = Logger.new(log_output)

      config_with_logger = Sidekiq::AsyncHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger)
      processor_with_logger.start

      exception = Async::TimeoutError.new("Request timed out")

      processor_with_logger.send(:handle_error, mock_request, exception)
      processor_with_logger.stop

      expect(log_output.string).to match(/WARN.*\[Sidekiq::AsyncHttp\] Request #{Regexp.escape(mock_request.id)} failed with Async::TimeoutError/)
      expect(log_output.string).to match(/enqueued TestWorkers::ErrorWorker/)
    end

    it "handles errors during enqueue gracefully", :disable_testing_mode do
      setter = double(Sidekiq::Job::Setter)
      allow(TestWorkers::ErrorWorker).to receive(:set).and_return(setter)
      allow(setter).to receive(:perform_async).and_raise(StandardError.new("Sidekiq error"))

      log_output = StringIO.new
      logger = Logger.new(log_output)

      config_with_logger = Sidekiq::AsyncHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger)
      processor_with_logger.start

      exception = StandardError.new("Test error")

      expect {
        processor_with_logger.send(:handle_error, mock_request, exception)
      }.not_to raise_error

      processor_with_logger.stop
      expect(log_output.string).to match(/\[Sidekiq::AsyncHttp\] Failed to enqueue error worker for request #{Regexp.escape(mock_request.id)}/)
    end

    it "includes backtrace in error hash" do
      exception = StandardError.new("Test error")
      exception.set_backtrace(["line 1", "line 2", "line 3"])

      processor.send(:handle_error, mock_request, exception)

      expect(TestWorkers::ErrorWorker.jobs.size).to eq(1)
      error_hash = TestWorkers::ErrorWorker.jobs.last["args"].first
      expect(error_hash["backtrace"]).to eq(["line 1", "line 2", "line 3"])
    end
  end

  describe "graceful shutdown", :disable_testing_mode do
    let(:mock_client) { double("Async::HTTP::Client") }
    let(:mock_headers) { double("Headers", to_h: {"Content-Type" => "application/json"}) }
    let(:mock_async_response) do
      double("Async::HTTP::Response",
        status: 200,
        headers: mock_headers,
        protocol: "HTTP/1.1")
    end

    before do
      allow(Sidekiq::Client).to receive(:push).and_return("new-jid")
    end

    it "completes all in-flight requests during clean shutdown" do
      # Set up HTTP client mock
      allow(Async::HTTP::Client).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:call).and_return(mock_async_response)
      allow(mock_async_response).to receive(:body).and_return(StringIO.new("response body"))

      processor.start

      # Enqueue a request
      request = create_request_task(
        jid: "jid-clean"
      )
      processor.enqueue(request)

      # Wait for request to complete
      processor.wait_for_idle(timeout: 2)

      # Verify request completed (no in-flight)
      expect(metrics.inflight_count).to eq(0)

      # Stop with timeout
      processor.stop(timeout: 1)

      # Should have completed the request (still no in-flight after stop)
      expect(metrics.inflight_count).to eq(0)
    end

    it "re-enqueues incomplete requests when timeout expires" do
      # Set up slow HTTP response that won't complete in time
      stub_request(:get, "https://api.example.com/users")
        .to_return do
          sleep(0.2) # Simulate slow request
          {status: 200, body: "response body", headers: {}}
        end

      processor.start

      # Enqueue a request
      request = create_request_task(
        jid: "jid-timeout",
        job_args: [4, 5, 6]
      )
      processor.enqueue(request)
      processor.wait_for_processing

      # Stop with short timeout (request won't complete)
      processor.stop(timeout: 0.001)

      # Should re-enqueue the incomplete request via Sidekiq::Client.push
      expect(Sidekiq::Client).to have_received(:push) do |job|
        expect(job["class"]).to eq("TestWorkers::Worker")
        expect(job["args"]).to eq([4, 5, 6])
      end
    end

    it "re-enqueues multiple incomplete requests" do
      # Set up slow HTTP response
      stub_request(:get, "https://api.example.com/users")
        .to_return do
          sleep(0.2) # Simulate slow request
          {status: 200, body: "response body", headers: {}}
        end

      processor.start

      # Enqueue multiple requests
      request1 = create_request_task(
        jid: "jid-multi-1",
        job_args: [10, 20]
      )
      request2 = create_request_task(
        jid: "jid-multi-2",
        job_args: [30, 40]
      )
      request3 = create_request_task(
        jid: "jid-multi-3",
        job_args: [50, 60]
      )

      processor.enqueue(request1)
      processor.enqueue(request2)
      processor.enqueue(request3)

      # Wait for requests to start processing
      processor.wait_for_processing

      # Stop with short timeout
      processor.stop(timeout: 0.001)

      # Should re-enqueue all incomplete requests
      expect(Sidekiq::Client).to have_received(:push).exactly(3).times do |job|
        expect(job["class"]).to eq("TestWorkers::Worker")
        expect([[10, 20], [30, 40], [50, 60]]).to include(job["args"])
      end
    end

    it "logs re-enqueued requests at info level" do
      # Set up slow HTTP response
      stub_request(:get, "https://api.example.com/users")
        .to_return do
          sleep(0.2) # Simulate slow request
          {status: 200, body: "response body", headers: {}}
        end

      log_output = StringIO.new
      logger = Logger.new(log_output)

      config_with_logger = Sidekiq::AsyncHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger)

      processor_with_logger.start

      # Enqueue a request
      request = create_request_task(
        jid: "jid-log"
      )
      processor_with_logger.enqueue(request)

      # Wait for request to start processing
      processor_with_logger.wait_for_processing

      # Stop with short timeout
      processor_with_logger.stop(timeout: 0.001)

      # Check log output
      expect(log_output.string).to match(/\[Sidekiq::AsyncHttp\] Re-enqueued incomplete request #{Regexp.escape(request.id)} to TestWorkers::Worker/)
    end

    it "handles errors during re-enqueue gracefully", :disable_testing_mode do
      # Set up slow HTTP response
      stub_request(:get, "https://api.example.com/users")
        .to_return do
          sleep(0.2) # Simulate slow request
          {status: 200, body: "response body", headers: {}}
        end

      # Make re-enqueue fail
      allow(Sidekiq::Client).to receive(:push).and_raise(StandardError.new("Enqueue failed"))

      log_output = StringIO.new
      logger = Logger.new(log_output)

      config_with_logger = Sidekiq::AsyncHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger)

      processor_with_logger.start

      # Enqueue a request
      request = create_request_task(
        job_args: [7, 8, 9]
      )
      processor_with_logger.enqueue(request)
      processor_with_logger.wait_for_processing

      # Stop should not raise error
      expect {
        processor_with_logger.stop(timeout: 0.001)
      }.not_to raise_error

      # Check error was logged
      expect(log_output.string).to match(/\[Sidekiq::AsyncHttp\] Failed to re-enqueue request #{Regexp.escape(request.id)}/)
    end
  end
end
