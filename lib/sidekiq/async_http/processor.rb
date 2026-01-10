# frozen_string_literal: true

require "concurrent"
require "async"
require "async/queue"
require "async/http"

module Sidekiq
  module AsyncHttp
    # Core processor that handles async HTTP requests in a dedicated thread
    class Processor
      STATES = %i[stopped running draining stopping].freeze

      attr_reader :config, :metrics, :connection_pool

      def initialize(config = nil, metrics: nil, connection_pool: nil)
        @config = config || Sidekiq::AsyncHttp.configuration
        @metrics = metrics || Metrics.new
        @connection_pool = connection_pool || ConnectionPool.new(@config, metrics: @metrics)

        @queue = Thread::Queue.new
        @state = Concurrent::AtomicReference.new(:stopped)
        @reactor_thread = nil
        @shutdown_barrier = Concurrent::Event.new
        @reactor_ready = Concurrent::Event.new
        @in_flight_requests = Concurrent::Hash.new
        @in_flight_lock = Mutex.new
      end

      # Start the processor
      # @return [void]
      def start
        return if running?

        @state.set(:running)
        @shutdown_barrier.reset
        @reactor_ready.reset

        @reactor_thread = Thread.new do
          Thread.current.name = "async-http-processor"
          run_reactor
        rescue => e
          # Log error but don't crash
          @config.effective_logger&.error("Async HTTP Processor error: #{e.message}\n#{e.backtrace.join("\n")}")
        ensure
          @state.set(:stopped)
        end

        # Block until the reactor is ready
        @reactor_ready.wait
      end

      # Stop the processor
      # @param timeout [Numeric, nil] how long to wait for in-flight requests (seconds)
      # @return [void]
      def stop(timeout: nil)
        return if stopped?

        @state.set(:stopping)

        # Signal the reactor thread to stop accepting new requests
        @shutdown_barrier.set

        # Wait for in-flight requests to complete
        if timeout && timeout > 0
          deadline = Time.now + timeout
          while @metrics.in_flight_count > 0 && Time.now < deadline
            sleep(0.001)
          end
        end

        # Re-enqueue any remaining in-flight tasks
        tasks_to_reenqueue = []
        @in_flight_lock.synchronize do
          tasks_to_reenqueue = @in_flight_requests.values
          @in_flight_requests.clear
        end

        # Re-enqueue each incomplete task
        tasks_to_reenqueue.each do |task|
          # Re-enqueue the original job
          task.reenqueue_job

          # Log re-enqueue
          @config.effective_logger&.info(
            "Async HTTP re-enqueued incomplete request #{task.id} to #{task.job_worker_class.name}"
          )
        rescue => e
          @config.effective_logger&.error(
            "Async HTTP failed to re-enqueue request #{task.id}: #{e.class} - #{e.message}"
          )
        end

        # Wait for reactor thread to finish
        if @reactor_thread&.alive?
          @reactor_thread.join(5) # Give it 5 seconds to clean up
        end

        # Close connection pool
        @connection_pool.close_all

        @state.set(:stopped)
      end

      # Drain the processor (stop accepting new requests)
      # @return [void]
      def drain
        @state.set(:draining) if running?
      end

      # Enqueue a request task for processing
      # @param task [RequestTask] the request task to enqueue
      # @raise [RuntimeError] if processor is not running or draining
      # @return [void]
      def enqueue(task)
        unless running? || draining?
          raise "Cannot enqueue request: processor is #{state}"
        end

        task.enqueued!
        @queue.push(task)
      end

      # Check if processor is running
      # @return [Boolean]
      def running?
        @state.get == :running
      end

      # Check if processor is stopped
      # @return [Boolean]
      def stopped?
        @state.get == :stopped
      end

      # Check if processor is draining
      # @return [Boolean]
      def draining?
        @state.get == :draining
      end

      # Check if processor is stopping
      # @return [Boolean]
      def stopping?
        @state.get == :stopping
      end

      # Get current state
      # @return [Symbol]
      def state
        @state.get
      end

      # Wait for the queue to be empty and all in-flight requests to complete.
      # This is mainly for use in tests.
      # @param timeout [Numeric] maximum time to wait in seconds (default: 5)
      # @return [Boolean] true if processing completed, false if timeout reached
      # @api private
      def wait_for_idle(timeout: 1)
        deadline = Time.now + timeout
        while Time.now <= deadline do
          return true if @queue.empty? && @metrics.in_flight_count == 0
          sleep(0.001)
        end
        false
      end

      # Wait for at least one request to start processing. This is mainly for use in tests.
      # @param timeout [Numeric] maximum time to wait in seconds (default: 5)
      # @return [Boolean] true if a request started processing, false if timeout reached
      # @api private
      def wait_for_processing(timeout: 1)
        deadline = Time.now + timeout
        while Time.now <= deadline do
          return true if @metrics.in_flight_count > 0
          sleep(0.001)
        end
        false
      end

      private

      # Run the async reactor loop
      # @return [void]
      def run_reactor
        Async do |task|
          # Signal that the reactor is ready
          @reactor_ready.set

          @config.effective_logger&.info("Async HTTP Processor started")

          loop do
            break if stopping? || @shutdown_barrier.set?

            # Pop request task from queue with timeout to periodically check shutdown
            request_task = dequeue_request(timeout: 0.1)
            next unless request_task

            # Check state again after dequeue
            break if stopping?

            # Check if we're at max connections limit
            if @metrics.in_flight_count >= @config.max_connections
              @config.effective_logger&.warn("Async HTTP max connections reached, applying backpressure")

              # Handle backpressure according to configured strategy
              begin
                @connection_pool.check_capacity!(request_task.request)
              rescue Sidekiq::AsyncHttp::BackpressureError => e
                # Request was dropped by backpressure strategy
                @config.effective_logger&.error("Async HTTP request dropped by backpressure: #{e.message}")
                next
              end
            end

            # Spawn a new fiber to process this request task
            task.async do
              process_request(request_task)
            rescue => e
              @config.effective_logger&.error("Async HTTP Error processing request: #{e.inspect}\n#{e.backtrace.join("\n")}")
            end
          end

          @config.effective_logger&.info("Async HTTP Processor stopped")
        rescue Async::Stop
          # Normal shutdown signal
          @config.effective_logger&.info("Async HTTP Reactor received stop signal")
        rescue => e
          @config.effective_logger&.error("Async HTTP Reactor loop error: #{e.inspect}\n#{e.backtrace.join("\n")}")
        end
      end

      # Dequeue a request task with timeout
      # @param timeout [Numeric] timeout in seconds
      # @return [RequestTask, nil] the request task or nil if timeout
      def dequeue_request(timeout:)
        Timeout.timeout(timeout) do
          @queue.pop
        end
      rescue Timeout::Error
        nil
      end

      # Process a single HTTP request task
      # @param task [RequestTask] the request task to process
      # @return [void]
      def process_request(task)
        # Store task in fiber-local storage for error handling
        Fiber[:current_request] = task

        # Track in-flight task
        @in_flight_lock.synchronize do
          @in_flight_requests[task.id] = task
        end

        # Record request start
        start_time = Time.now
        @metrics.record_request_start(task)

        begin
          # Execute HTTP request with connection pool
          @connection_pool.with_client(task.request.url) do |client|
            # Build Async::HTTP::Request
            http_request = build_http_request(task.request)

            # Execute with timeout
            response_data = Async::Task.current.with_timeout(task.request.timeout || @config.default_request_timeout) do
              async_response = client.call(http_request)
              body = async_response.read

              # Build response object
              {
                status: async_response.status,
                headers: async_response.headers.to_h,
                body: body,
                protocol: async_response.protocol
              }
            end

            # Calculate duration
            duration = Time.now - start_time

            # Build Response object
            response = build_response(task, response_data, duration)

            # Record completion
            @metrics.record_request_complete(task, duration)

            # Handle success
            handle_success(task, response)
          end
        rescue Async::TimeoutError => e
          Time.now
          @metrics.record_error(task, :timeout)
          handle_error(task, e)
        rescue => e
          Time.now
          error_type = classify_error(e)
          @metrics.record_error(task, error_type)
          handle_error(task, e)
        ensure
          # Remove from in-flight tracking
          @in_flight_lock.synchronize do
            @in_flight_requests.delete(task.id)
          end
          Fiber[:current_request] = nil
        end
      end

      # Build an Async::HTTP::Request from our Request object
      # @param request [Request] the request object
      # @return [Async::HTTP::Request] the async HTTP request
      def build_http_request(request)
        uri = URI.parse(request.url)

        # Create headers
        headers = (request.headers || {}).dup

        # Set body if present
        body_content = if request.body
          [request.body]
        end

        # Build the request with correct parameter order: scheme, authority, method, path, version, headers, body
        Async::HTTP::Protocol::Request.new(
          uri.scheme,                      # scheme
          uri.authority,                   # authority (host:port)
          request.method.to_s.upcase,      # method
          uri.request_uri || "/",          # path
          nil,                             # version (nil = auto)
          headers,                         # headers
          body_content                     # body
        )
      end

      # Build a Response object from async response data
      # @param task [RequestTask] the original request task
      # @param response_data [Hash] the response data
      # @param duration [Float] request duration in seconds
      # @return [Response] the response object
      def build_response(task, response_data, duration)
        # For now, return a simple hash-based response
        # This will be replaced with proper Response Data.define object later
        {
          status: response_data[:status],
          headers: response_data[:headers],
          body: response_data[:body],
          duration: duration,
          request_id: task.id,
          protocol: response_data[:protocol],
          url: task.request.url,
          method: task.request.method
        }
      end

      # Classify an error by type
      # @param exception [Exception] the exception
      # @return [Symbol] the error type
      def classify_error(exception)
        case exception
        when Async::TimeoutError
          :timeout
        when OpenSSL::SSL::SSLError
          :ssl
        when Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH
          :connection
        else
          :unknown
        end
      end

      # Handle successful response
      # @param task [RequestTask] the request task
      # @param response [Hash] the response hash
      # @return [void]
      def handle_success(task, response)
        # Get worker class from class name
        worker_class = resolve_worker_class(task.success_worker)

        # Enqueue the success worker with response and original args
        worker_class.perform_async(response, *task.job_args)

        # Log success
        @config.effective_logger&.info(
          "Async HTTP request #{task.id} succeeded with status #{response[:status]}, " \
          "enqueued #{task.success_worker}"
        )
      rescue => e
        # Log error but don't crash the processor
        @config.effective_logger&.error(
          "Async HTTP failed to enqueue success worker for request #{task.id}: #{e.class} - #{e.message}"
        )
      end

      # Handle error response
      # @param task [RequestTask] the request task
      # @param exception [Exception] the exception
      # @return [void]
      def handle_error(task, exception)
        # Build Error object from exception
        error = Error.from_exception(exception, request_id: task.id)

        # Get worker class from class name
        worker_class = resolve_worker_class(task.error_worker)

        # Enqueue the error worker with error hash and original args
        worker_class.perform_async(error.to_h, *task.job_args)

        # Log error
        @config.effective_logger&.warn(
          "Async HTTP request #{task.id} failed with #{error.error_type} error (#{error.class_name}): #{error.message}, " \
          "enqueued #{task.error_worker}"
        )
      rescue => e
        # Log error but don't crash the processor
        @config.effective_logger&.error(
          "Async HTTP failed to enqueue error worker for request #{task.id}: #{e.class} - #{e.message}"
        )
      end

      # Resolve worker class from class name string
      # Handles module namespaces correctly
      # @param class_name [String] the worker class name
      # @return [Class] the worker class
      # @raise [NameError] if class cannot be found
      def resolve_worker_class(class_name)
        Object.const_get(class_name)
      end
    end
  end
end
