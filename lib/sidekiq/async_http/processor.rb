# frozen_string_literal: true

require "concurrent"
require "async"
require "async/queue"
require "async/http"

module Sidekiq
  module AsyncHttp
    # Core processor that handles async HTTP requests in a dedicated thread
    class Processor
      include TimeHelper

      STATES = %i[stopped running draining stopping].freeze

      # Timing constants for the reactor loop
      DEQUEUE_TIMEOUT = 1.0          # Seconds to wait when dequeueing requests
      INFLIGHT_UPDATE_INTERVAL = 5   # Seconds between inflight stats updates
      SHUTDOWN_POLL_INTERVAL = 0.001 # Seconds to sleep while polling during shutdown

      # @return [Configuration] the configuration object for the processor
      attr_reader :config

      # @return [Metrics] the metrics maintained by the processor
      attr_reader :metrics

      # @return [InflightRegistry] the inflight request registry
      attr_reader :inflight_registry

      # Callback to invoke after each request. Only available in testing mode.
      # @api private
      attr_accessor :testing_callback

      # Initialize the processor.
      #
      # @param config [Configuration] the configuration object
      # @return [void]
      def initialize(config = nil)
        @config = config || Sidekiq::AsyncHttp.configuration
        @metrics = Metrics.new
        @stats = Stats.new(@config)
        @inflight_registry = InflightRegistry.new(@config)
        @queue = Thread::Queue.new
        @state = Concurrent::AtomicReference.new(:stopped)
        @reactor_thread = nil
        @monitor_thread = MonitorThread.new(
          @config,
          @inflight_registry,
          -> { @tasks_lock.synchronize { @inflight_requests.keys } }
        )
        @shutdown_barrier = Concurrent::Event.new
        @reactor_ready = Concurrent::Event.new
        @inflight_requests = Concurrent::Hash.new
        @pending_tasks = Concurrent::Hash.new
        @tasks_lock = Mutex.new
        @testing_callback = nil
      end

      # Start the processor.
      #
      # @return [void]
      def start
        @tasks_lock.synchronize do
          return if starting? || running? || stopping?
          @state.set(:starting)
          @shutdown_barrier.reset
          @reactor_ready.reset
        end

        @reactor_thread = Thread.new do
          Thread.current.name = "async-http-processor"
          run_reactor
        rescue => e
          # Log error but don't crash
          @config.logger&.error("[Sidekiq::AsyncHttp] Processor error: #{e.message}\n#{e.backtrace.join("\n")}")

          raise if AsyncHttp.testing?
        ensure
          if @reactor_thread == Thread.current
            @tasks_lock.synchronize { @state.set(:stopped) }
          end
        end

        @monitor_thread.start
        @tasks_lock.synchronize { @state.set(:running) }

        # Block until the reactor is ready
        @reactor_ready.wait
      end

      # Stop the processor.
      #
      # @param timeout [Numeric, nil] how long to wait for in-flight requests (seconds)
      # @return [void]
      def stop(timeout: nil)
        # Atomically transition to stopping state under lock to ensure consistency
        # with other state-checking operations
        @tasks_lock.synchronize do
          return if stopped? || stopping? || starting?
          @state.set(:stopping)
        end

        # Signal the reactor thread to stop accepting new requests
        @shutdown_barrier.set

        # Interrupt the reactor's queue wait by pushing a sentinel value
        @queue.push(nil)

        # Wait for in-flight requests to complete
        if timeout && timeout > 0
          deadline = monotonic_time + timeout
          while !idle? && monotonic_time < deadline
            sleep(SHUTDOWN_POLL_INTERVAL)
          end
        end

        # Re-enqueue any remaining in-flight and pending tasks
        tasks_to_reenqueue = []
        @tasks_lock.synchronize do
          # Now that we have the lock again, atomically transition to stopped and clear collections
          @state.set(:stopped)
          tasks_to_reenqueue = @inflight_requests.values + @pending_tasks.values
          @inflight_requests.clear
          @pending_tasks.clear
        end

        # Clean up process-specific keys from Redis
        @stats.cleanup_process_keys

        # Re-enqueue each incomplete task
        tasks_to_reenqueue.each do |task|
          # Re-enqueue the original job
          task.reenqueue_job

          # Log re-enqueue
          @config.logger&.info(
            "[Sidekiq::AsyncHttp] Re-enqueued incomplete request #{task.id} to #{task.job_worker_class.name}"
          )
        rescue => e
          @config.logger&.error(
            "[Sidekiq::AsyncHttp] Failed to re-enqueue request #{task.id}: #{e.class} - #{e.message}"
          )

          raise if AsyncHttp.testing?
        end

        @reactor_thread.join(1) if @reactor_thread&.alive?
        @reactor_thread.kill if @reactor_thread&.alive?
        @reactor_thread = nil

        # Stop the monitor thread
        @monitor_thread.stop
      end

      # Drain the processor (stop accepting new requests).
      #
      # @return [void]
      def drain
        @tasks_lock.synchronize do
          return unless running?

          @state.set(:draining)
        end

        @config.logger&.info("[Sidekiq::AsyncHttp] Processor draining (no longer accepting new requests)")
      end

      # Enqueue a request task for processing.
      #
      # @param task [RequestTask] the request task to enqueue
      # @raise [NotRunningError] if processor is not running
      # @raise [MaxCapacityError] if at max capacity
      # @return [void]
      def enqueue(task)
        unless running?
          raise NotRunningError.new("Cannot enqueue request: processor is #{state}")
        end

        # Check capacity - raise error if at max connections
        if inflight_count >= @config.max_connections
          @metrics.record_refused
          @stats.record_refused
          raise MaxCapacityError.new("Cannot enqueue request: already at max capacity (#{@config.max_connections} connections)")
        end

        task.enqueued!
        @queue.push(task)
      end

      # Get the current processor status.
      #
      # @return [Symbol] the current status
      def status
        @state.get
      end

      # Check if processor is starting.
      #
      # @return [Boolean]
      def starting?
        state == :starting
      end

      # Check if processor is running.
      #
      # @return [Boolean]
      def running?
        state == :running
      end

      # Check if processor is stopped.
      #
      # @return [Boolean]
      def stopped?
        state == :stopped
      end

      # Check if processor is draining.
      #
      # @return [Boolean]
      def draining?
        state == :draining
      end

      # Check if processor is drained (draining and idle).
      #
      # @return [Boolean]
      def drained?
        state == :draining && idle?
      end

      # Check if processor is stopping.
      #
      # @return [Boolean]
      def stopping?
        state == :stopping
      end

      # Check if processor is idle (no queued or in-flight requests).
      #
      # @return [Boolean]
      def idle?
        @tasks_lock.synchronize do
          @queue.empty? && @pending_tasks.empty? && @inflight_requests.empty?
        end
      end

      # Get current state.
      #
      # @return [Symbol]
      def state
        @state.get
      end

      # Get the number of in-flight requests.
      #
      # @return [Integer]
      def inflight_count
        @inflight_requests.size
      end

      # Wait for the processor to start.
      #
      # @param timeout [Numeric] maximum time to wait in seconds (default: 5)
      # @return [Boolean] true if started, false if timeout reached
      # @api private
      def wait_for_running(timeout: 5)
        start
        deadline = monotonic_time + timeout
        while monotonic_time <= deadline
          return true if running?
          sleep(SHUTDOWN_POLL_INTERVAL)
        end
        false
      end

      # Wait for the queue to be empty and all in-flight requests to complete.
      # This is mainly for use in tests.
      #
      # @param timeout [Numeric] maximum time to wait in seconds (default: 5)
      # @return [Boolean] true if processing completed, false if timeout reached
      # @api private
      def wait_for_idle(timeout: 1)
        deadline = monotonic_time + timeout
        while monotonic_time <= deadline
          return true if idle?
          sleep(SHUTDOWN_POLL_INTERVAL)
        end
        false
      end

      # Wait for at least one request to start processing. This is mainly for use in tests.
      #
      # @param timeout [Numeric] maximum time to wait in seconds (default: 5)
      # @return [Boolean] true if a request started processing, false if timeout reached
      # @api private
      def wait_for_processing(timeout: 1)
        deadline = monotonic_time + timeout
        while monotonic_time <= deadline
          return true if !@inflight_requests.empty? || !@pending_tasks.empty?
          sleep(SHUTDOWN_POLL_INTERVAL)
        end
        false
      end

      # Run the processor in a block. This is intended for use in tests to
      # ensure the processor is started and stopped properly.
      #
      # @api private
      def run(&block)
        start
        wait_for_running
        yield
      ensure
        stop
        wait_for_idle
      end

      private

      # Run the async reactor loop.
      #
      # @return [void]
      def run_reactor
        Async do |task|
          # Signal that the reactor is ready
          @reactor_ready.set

          @config.logger&.info("[Sidekiq::AsyncHttp] Processor started")

          last_inflight_update = monotonic_time - INFLIGHT_UPDATE_INTERVAL
          # Main loop: monitor shutdown/drain and process requests
          loop do
            break if stopping? || stopped?

            # Update inflight stats periodically
            if monotonic_time - last_inflight_update >= INFLIGHT_UPDATE_INTERVAL
              @stats.update_inflight(inflight_count, @config.max_connections)
              last_inflight_update = monotonic_time
            end

            # Pop request task from queue with timeout to periodically check shutdown
            request_task = dequeue_request(timeout: DEQUEUE_TIMEOUT)
            next unless request_task

            # Track as pending immediately to avoid race condition with stop()
            @tasks_lock.synchronize do
              @pending_tasks[request_task.id] = request_task
            end

            # If we've dequeued a task, we must process it even if stopping
            # to avoid losing the request (shutdown will handle re-enqueuing if incomplete)

            # Spawn a new fiber to process this request task
            task.async do
              process_request(request_task)
            rescue => e
              @config.logger&.error("[Sidekiq::AsyncHttp] Error processing request: #{e.inspect}\n#{e.backtrace.join("\n")}")

              warn(e.inspect, e.backtrace) if AsyncHttp.testing?
            end
          end

          @config.logger&.info("[Sidekiq::AsyncHttp] Processor stopped")
        rescue Async::Stop
          # Normal shutdown signal
          @config.logger&.info("[Sidekiq::AsyncHttp] Reactor received stop signal")
        rescue => e
          @config.logger&.error("[Sidekiq::AsyncHttp] Reactor loop error: #{e.inspect}\n#{e.backtrace.join("\n")}")
        end
      end

      # Dequeue a request task with timeout.
      #
      # @param timeout [Numeric] timeout in seconds
      # @return [RequestTask, nil] the request task or nil if timeout
      def dequeue_request(timeout:)
        @queue.pop(timeout: timeout)
      rescue ThreadError
        # Queue is empty and timeout expired
        nil
      end

      # Process a single HTTP request task.
      #
      # @param task [RequestTask] the request task to process
      # @return [void]
      def process_request(task)
        # Move from pending to in-flight tracking
        @tasks_lock.synchronize do
          @pending_tasks.delete(task.id)
          @inflight_requests[task.id] = task
        end

        # Register in Redis for crash recovery
        @inflight_registry.register(task)

        # Mark task as started
        task.started!

        # Record request start
        @metrics.record_request_start

        begin
          http_client = http_client(task.request)
          http_request = build_http_request(task.request)
          http_request.headers.add("x-request-id", task.id)

          # Execute with timeout
          response_data = Async::Task.current.with_timeout(task.request.timeout || @config.default_request_timeout) do
            async_response = http_client.call(http_request)
            headers_hash = async_response.headers.to_h
            body = read_response_body(async_response, headers_hash) unless stopping? || stopped?

            # Build response object
            {
              status: async_response.status,
              headers: headers_hash,
              body: body,
              protocol: async_response.protocol
            }
          end

          return if stopping? || stopped?

          task.completed!
          response = build_response(task, response_data)
          handle_success(task, response)
        rescue => e
          task.completed!
          error_type = classify_error(e)
          @metrics.record_error(error_type)
          @stats.record_error(error_type)
          handle_error(task, e)
        ensure
          # Remove from in-flight tracking
          @tasks_lock.synchronize do
            @inflight_requests.delete(task.id)
          end
          @metrics.record_request_complete(task.duration)
          @stats.record_request(task.duration)

          @testing_callback&.call(task) if AsyncHttp.testing?
        end
      end

      # Read response body with size validation.
      #
      # Reads the async HTTP response body asynchronously to completion, which allows
      # the connection to be reused. The async-http client handles connection pooling
      # and keep-alive internally. Using iteration instead of read() ensures non-blocking
      # I/O that yields to the reactor.
      #
      # @param async_response [Async::HTTP::Protocol::Response] the async HTTP response
      # @param headers_hash [Hash] the response headers
      # @return [String, nil] the response body or nil if no body present
      # @raise [ResponseTooLargeError] if body exceeds max_response_size
      def read_response_body(async_response, headers_hash)
        return nil unless async_response.body

        # Check content-length header if present
        content_length = headers_hash["content-length"]&.to_i
        if content_length && content_length > @config.max_response_size
          raise ResponseTooLargeError.new(
            "Response body size (#{content_length} bytes) exceeds maximum allowed size (#{@config.max_response_size} bytes)"
          )
        end

        # Read body while checking size
        chunks = []
        total_size = 0
        async_response.body.each do |chunk|
          total_size += chunk.bytesize
          if total_size > @config.max_response_size
            raise ResponseTooLargeError.new(
              "Response body size exceeded maximum allowed size (#{@config.max_response_size} bytes)"
            )
          end
          chunks << chunk
        end
        chunks.join
      end

      # Create an Async::HTTP::Client for the given request.
      #
      # @param request [Request] the request object
      # @return [Async::HTTP::Client] the async HTTP client
      def http_client(request)
        endpoint = Async::HTTP::Endpoint.parse(
          request.url,
          connect_timeout: request.connect_timeout,
          idle_timeout: @config.idle_connection_timeout
        )
        Async::HTTP::Client.new(endpoint)
      end

      # Build an Async::HTTP::Request from our Request object.
      #
      # @param request [Request] the request object
      # @return [Async::HTTP::Request] the async HTTP request
      def build_http_request(request)
        uri = URI.parse(request.url)

        # Create headers - must be a Protocol::HTTP::Headers object, not a Hash
        headers = Protocol::HTTP::Headers.new
        (request.headers || {}).each do |key, value|
          headers.add(key, value)
        end

        # Set body if present - use Protocol::HTTP::Body::Buffered for proper handling
        body_content = if request.body
          body_bytes = request.body.to_s
          # Protocol::HTTP::Body::Buffered will automatically set Content-Length
          Protocol::HTTP::Body::Buffered.wrap([body_bytes])
        end

        # Build the request with correct parameter order: scheme, authority, method, path, version, headers, body
        Async::HTTP::Protocol::Request.new(
          uri.scheme,                      # scheme
          uri.authority,                   # authority (host:port)
          request.method.to_s.upcase,      # method
          uri.request_uri,                 # path
          nil,                             # version (nil = auto)
          headers,                         # headers
          body_content                     # body
        )
      end

      # Build a Response object from async response data.
      #
      # @param task [RequestTask] the original request task
      # @param http_response [Hash] the response data
      # @return [Response] the response object
      def build_response(task, http_response)
        Response.new(
          status: http_response[:status],
          headers: http_response[:headers],
          body: http_response[:body],
          protocol: http_response[:protocol],
          duration: task.duration,
          request_id: task.id,
          url: task.request.url,
          method: task.request.method
        )
      end

      # Classify an error by type.
      #
      # @param exception [Exception] the exception
      # @return [Symbol] the error type
      def classify_error(exception)
        case exception
        when Async::TimeoutError
          :timeout
        when ResponseTooLargeError
          :response_too_large
        when OpenSSL::SSL::SSLError
          :ssl
        when Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH
          :connection
        else
          :unknown
        end
      end

      # Handle successful response.
      #
      # @param task [RequestTask] the request task
      # @param response [Response] the response object
      # @return [void]
      def handle_success(task, response)
        if stopped?
          @config.logger&.warn("[Sidekiq::AsyncHttp] Request #{task.id} succeeded after processor was stopped")
          return
        end

        task.success!(response)

        # Unregister from Redis after successful callback enqueue
        @inflight_registry.unregister(task.id)

        @config.logger&.debug(
          "[Sidekiq::AsyncHttp] Request #{task.id} succeeded with status #{response.status}, " \
          "enqueued #{task.completion_worker}"
        )
      end

      # Handle error response.
      #
      # @param task [RequestTask] the request task
      # @param exception [Exception] the exception
      # @return [void]
      def handle_error(task, exception)
        if stopped?
          @config.logger&.warn("[Sidekiq::AsyncHttp] Request #{task.id} failed after processor was stopped")
          return
        end

        task.error!(exception)

        # Unregister from Redis after error callback enqueue
        @inflight_registry.unregister(task.id)

        @config.logger&.warn(
          "[Sidekiq::AsyncHttp] Request #{task.id} failed with #{exception.class.name}: #{exception.message}, " \
          "enqueued #{task.error_worker}"
        )
      rescue => e
        # Log error but don't crash the processor
        @config.logger&.error(
          "[Sidekiq::AsyncHttp] Failed to enqueue error worker for request #{task.id}: #{e.class} - #{e.message}"
        )
        raise if AsyncHttp.testing?
      end
    end
  end
end
