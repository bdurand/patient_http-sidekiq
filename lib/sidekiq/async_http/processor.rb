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

      attr_reader :config, :metrics

      def initialize(config = nil, metrics: nil)
        @config = config || Sidekiq::AsyncHttp.configuration
        @metrics = metrics || Metrics.new

        @queue = Thread::Queue.new
        @state = Concurrent::AtomicReference.new(:stopped)
        @reactor_thread = nil
        @shutdown_barrier = Concurrent::Event.new
        @reactor_ready = Concurrent::Event.new
        @in_flight_requests = Concurrent::Hash.new
        @pending_tasks = Concurrent::Hash.new
        @tasks_lock = Mutex.new
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
          @config.logger&.error("Async HTTP Processor error: #{e.message}\n#{e.backtrace.join("\n")}")
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
          deadline = monotonic_time + timeout
          while @metrics.in_flight_count > 0 && monotonic_time < deadline
            sleep(0.001)
          end
        end

        # Re-enqueue any remaining in-flight and pending tasks
        tasks_to_reenqueue = []
        @tasks_lock.synchronize do
          tasks_to_reenqueue = @in_flight_requests.values + @pending_tasks.values
          @in_flight_requests.clear
          @pending_tasks.clear
        end

        # Re-enqueue each incomplete task
        tasks_to_reenqueue.each do |task|
          # Re-enqueue the original job
          task.reenqueue_job

          # Log re-enqueue
          @config.logger&.info(
            "Async HTTP re-enqueued incomplete request #{task.id} to #{task.job_worker_class.name}"
          )
        rescue => e
          @config.logger&.error(
            "Async HTTP failed to re-enqueue request #{task.id}: #{e.class} - #{e.message}"
          )
        end

        # Wait for reactor thread to finish
        if @reactor_thread&.alive?
          @reactor_thread.join(5) # Give it 5 seconds to clean up
        end

        @state.set(:stopped)
      end

      # Drain the processor (stop accepting new requests)
      # @return [void]
      def drain
        @state.set(:draining) if running?
      end

      # Enqueue a request task for processing
      # @param task [RequestTask] the request task to enqueue
      # @raise [RuntimeError] if processor is not running or if at capacity
      # @return [void]
      def enqueue(task)
        unless running?
          raise "Cannot enqueue request: processor is #{state}"
        end

        # Check capacity - raise error if at max connections
        if @metrics.in_flight_count >= @config.max_connections
          raise "Cannot enqueue request: at capacity (#{@metrics.in_flight_count}/#{@config.max_connections})"
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
        deadline = monotonic_time + timeout
        while monotonic_time <= deadline do
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
        deadline = monotonic_time + timeout
        while monotonic_time <= deadline do
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

          @config.logger&.info("Async HTTP Processor started")

          # Main loop: monitor shutdown/drain and process requests
          loop do
            break if stopping? || @shutdown_barrier.set?

            # Pop request task from queue with timeout to periodically check shutdown
            request_task = dequeue_request(timeout: 0.1)
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
              @config.logger&.error("Async HTTP Error processing request: #{e.inspect}\n#{e.backtrace.join("\n")}")
            end
          end

          @config.logger&.info("Async HTTP Processor stopped")
        rescue Async::Stop
          # Normal shutdown signal
          @config.logger&.info("Async HTTP Reactor received stop signal")
        rescue => e
          @config.logger&.error("Async HTTP Reactor loop error: #{e.inspect}\n#{e.backtrace.join("\n")}")
        end
      end

      # Dequeue a request task with timeout
      # @param timeout [Numeric] timeout in seconds
      # @return [RequestTask, nil] the request task or nil if timeout
      def dequeue_request(timeout:)
        @queue.pop(timeout: timeout)
      rescue ThreadError
        # Queue is empty and timeout expired
        nil
      end

      # Process a single HTTP request task
      # @param task [RequestTask] the request task to process
      # @return [void]
      def process_request(task)
        # Store task in fiber-local storage for error handling
        Fiber[:current_request] = task

        # Move from pending to in-flight tracking
        @tasks_lock.synchronize do
          @pending_tasks.delete(task.id)
          @in_flight_requests[task.id] = task
        end

        # Mark task as started
        task.started!

        # Record request start
        @metrics.record_request_start(task)

        begin
          # Parse the URL to get the endpoint
          uri = URI.parse(task.request.url)
          endpoint = Async::HTTP::Endpoint.parse(uri.to_s)

          # Create or reuse a client for this endpoint
          # Async::HTTP::Client handles connection pooling and reuse internally
          client = Async::HTTP::Client.new(
            endpoint,
            protocol: @config.http2_enabled? ? Async::HTTP::Protocol::HTTP2 : Async::HTTP::Protocol::HTTP1
          )

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

          # Mark task as completed
          task.completed!

          # Build Response object
          response = build_response(task, response_data)

          # Record completion
          @metrics.record_request_complete(task, task.duration)

          # Handle success
          handle_success(task, response)
        rescue Async::TimeoutError => e
          task.completed!
          @metrics.record_error(task, :timeout)
          handle_error(task, e)
        rescue => e
          task.completed!
          error_type = classify_error(e)
          @metrics.record_error(task, error_type)
          handle_error(task, e)
        ensure
          # Remove from in-flight tracking
          @tasks_lock.synchronize do
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
      # @return [Response] the response object
      def build_response(task, response_data)
        # For now, return a simple hash-based response
        # This will be replaced with proper Response Data.define object later
        {
          status: response_data[:status],
          headers: response_data[:headers],
          body: response_data[:body],
          duration: task.duration,
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
        @config.logger&.info(
          "Async HTTP request #{task.id} succeeded with status #{response[:status]}, " \
          "enqueued #{task.success_worker}"
        )
      rescue => e
        # Log error but don't crash the processor
        @config.logger&.error(
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
        @config.logger&.warn(
          "Async HTTP request #{task.id} failed with #{error.error_type} error (#{error.class_name}): #{error.message}, " \
          "enqueued #{task.error_worker}"
        )
      rescue => e
        # Log error but don't crash the processor
        @config.logger&.error(
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
