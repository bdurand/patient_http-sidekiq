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

      # Timing constants for the reactor loop
      DEQUEUE_TIMEOUT = 1.0          # Seconds to wait when dequeueing requests
      INFLIGHT_UPDATE_INTERVAL = 5   # Seconds between inflight stats updates

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
        @http_client_factory = HttpClientFactory.new(@config)
        @request_builder = RequestBuilder.new(@config)
        @response_reader = ResponseReader.new(@config)
        @lifecycle = LifecycleManager.new
        @metrics = Metrics.new
        @stats = Stats.new(@config)
        @inflight_registry = InflightRegistry.new(@config)
        @queue = Thread::Queue.new
        @reactor_thread = nil
        @monitor_thread = MonitorThread.new(
          @config,
          @inflight_registry,
          -> { @tasks_lock.synchronize { @inflight_requests.keys } }
        )
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
          return unless @lifecycle.start!
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
            @tasks_lock.synchronize { @lifecycle.stopped! }
          end
        end

        @monitor_thread.start
        @tasks_lock.synchronize { @lifecycle.running! }

        # Block until the reactor is ready
        @lifecycle.wait_for_reactor
      end

      # Stop the processor.
      #
      # @param timeout [Numeric, nil] how long to wait for in-flight requests (seconds)
      # @return [void]
      def stop(timeout: nil)
        # Atomically transition to stopping state under lock to ensure consistency
        # with other state-checking operations
        @tasks_lock.synchronize do
          return unless @lifecycle.stop!
        end

        # Interrupt the reactor's queue wait by pushing a sentinel value
        @queue.push(nil)

        # Wait for in-flight requests to complete
        if timeout && timeout > 0
          deadline = monotonic_time + timeout
          while !idle? && monotonic_time < deadline
            sleep(LifecycleManager::POLL_INTERVAL)
          end
        end

        # Re-enqueue any remaining in-flight and pending tasks
        tasks_to_reenqueue = []
        @tasks_lock.synchronize do
          # Now that we have the lock again, atomically transition to stopped and clear collections
          @lifecycle.stopped!
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
          return unless @lifecycle.drain!
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

      # Get the current processor state.
      #
      # @return [Symbol] the current state
      def state
        @lifecycle.state
      end

      # Check if processor is starting.
      #
      # @return [Boolean]
      def starting?
        @lifecycle.starting?
      end

      # Check if processor is running.
      #
      # @return [Boolean]
      def running?
        @lifecycle.running?
      end

      # Check if processor is stopped.
      #
      # @return [Boolean]
      def stopped?
        @lifecycle.stopped?
      end

      # Check if processor is draining.
      #
      # @return [Boolean]
      def draining?
        @lifecycle.draining?
      end

      # Check if processor is drained (draining and idle).
      #
      # @return [Boolean]
      def drained?
        @lifecycle.draining? && idle?
      end

      # Check if processor is stopping.
      #
      # @return [Boolean]
      def stopping?
        @lifecycle.stopping?
      end

      # Check if processor is idle (no queued or in-flight requests).
      #
      # @return [Boolean]
      def idle?
        @tasks_lock.synchronize do
          @queue.empty? && @pending_tasks.empty? && @inflight_requests.empty?
        end
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
        @lifecycle.wait_for_running(timeout: timeout)
      end

      # Wait for the queue to be empty and all in-flight requests to complete.
      # This is mainly for use in tests.
      #
      # @param timeout [Numeric] maximum time to wait in seconds (default: 5)
      # @return [Boolean] true if processing completed, false if timeout reached
      # @api private
      def wait_for_idle(timeout: 1)
        @lifecycle.wait_for_idle(timeout: timeout) { idle? }
      end

      # Wait for at least one request to start processing. This is mainly for use in tests.
      #
      # @param timeout [Numeric] maximum time to wait in seconds (default: 5)
      # @return [Boolean] true if a request started processing, false if timeout reached
      # @api private
      def wait_for_processing(timeout: 1)
        @lifecycle.wait_for_processing(timeout: timeout) do
          !@inflight_requests.empty? || !@pending_tasks.empty?
        end
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
          @lifecycle.reactor_ready!

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
          client = @http_client_factory.build(task.request)
          http_request = @request_builder.build(task.request)
          http_request.headers.add("x-request-id", task.id)

          # Execute with timeout
          response_data = Async::Task.current.with_timeout(task.request.timeout || @config.default_request_timeout) do
            async_response = client.call(http_request)
            headers_hash = async_response.headers.to_h
            body = @response_reader.read_body(async_response, headers_hash) unless stopping? || stopped?

            # Build response object
            {
              status: async_response.status,
              headers: headers_hash,
              body: body
            }
          end

          return if stopping? || stopped?

          task.completed!
          response = task.build_response(**response_data)
          handle_success(task, response)
        rescue => e
          task.completed!
          error_type = Error.error_type(e)
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
          "enqueued #{task.error_worker || task.sidekiq_job["class"]}\n#{exception.backtrace&.join("\n")}"
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
