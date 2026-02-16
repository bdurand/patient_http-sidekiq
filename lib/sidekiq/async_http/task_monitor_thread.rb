# frozen_string_literal: true

module Sidekiq
  module AsyncHttp
    # Background thread that maintains heartbeats and performs garbage collection
    # for in-flight HTTP requests.
    class TaskMonitorThread
      include AsyncHttpPool::TimeHelper

      # Minimum seconds to sleep between monitor thread checks
      MAX_MONITOR_SLEEP = 5.0

      # @return [Configuration] the configuration object
      attr_reader :config

      # @return [TaskMonitor] the inflight request registry
      attr_reader :task_monitor

      # Initialize the monitor thread.
      #
      # @param config [Configuration] the configuration object
      # @param task_monitor [TaskMonitor] the inflight request registry
      # @param inflight_ids_callback [Proc] callback to get current inflight request IDs
      # @return [void]
      def initialize(config, task_monitor, inflight_ids_callback)
        @config = config
        @task_monitor = task_monitor
        @inflight_ids_callback = inflight_ids_callback
        @thread = nil
        @running = Concurrent::AtomicBoolean.new(false)
        @stop_signal = Concurrent::Event.new
      end

      # Start the monitor thread.
      #
      # @return [void]
      def start
        return if @running.true?
        @running.make_true
        @stop_signal.reset

        @task_monitor.ping_process

        @thread = Thread.new do
          run
        rescue => e
          # Log error but don't crash
          @config.logger&.error("[Sidekiq::AsyncHttp] Monitor error: #{e.message}\n#{e.backtrace.join("\n")}")
          raise if AsyncHttp.testing?
        end

        @thread.name = "async-http-monitor"
      end

      # Stop the monitor thread.
      #
      # @return [void]
      def stop
        @running.make_false
        @stop_signal.set  # Interrupt the sleep immediately
        @thread&.join(1)
        @thread&.kill if @thread&.alive?
        @thread = nil
      end

      # Check if monitor thread is running.
      #
      # @return [Boolean]
      def running?
        @running.true?
      end

      private

      # Run the monitor loop.
      #
      # @return [void]
      def run
        @config.logger&.info("[Sidekiq::AsyncHttp] Monitor thread started")

        last_heartbeat_update = monotonic_time - @config.heartbeat_interval
        last_gc_attempt = monotonic_time - @config.heartbeat_interval

        loop do
          break unless @running.true?

          current_time = monotonic_time

          # Update heartbeats for all inflight requests
          if current_time - last_heartbeat_update >= @config.heartbeat_interval
            @task_monitor.ping_process
            update_heartbeats
            last_heartbeat_update = current_time
          end

          # Attempt garbage collection
          if current_time - last_gc_attempt >= @config.heartbeat_interval
            attempt_garbage_collection
            last_gc_attempt = current_time
          end

          # Sleep with interruptible wait - returns true if interrupted
          wait_time = @config.heartbeat_interval / 2.0
          wait_time = MAX_MONITOR_SLEEP if wait_time > MAX_MONITOR_SLEEP
          @stop_signal.wait(wait_time)
        end

        @config.logger&.info("[Sidekiq::AsyncHttp] Monitor thread stopped")
      end

      # Update heartbeats for all inflight requests.
      #
      # @return [void]
      def update_heartbeats
        request_ids = @inflight_ids_callback.call
        return if request_ids.empty?

        @task_monitor.update_heartbeats(request_ids)

        @config.logger&.debug("[Sidekiq::AsyncHttp] Updated heartbeats for #{request_ids.size} inflight requests")
      rescue => e
        @config.logger&.error("[Sidekiq::AsyncHttp] Failed to update heartbeats: #{e.class} - #{e.message}")
        raise if AsyncHttp.testing?
      end

      # Attempt to acquire GC lock and clean up orphaned requests.
      #
      # @return [void]
      def attempt_garbage_collection
        # Check if GC is needed based on coordinated timestamp
        return unless @task_monitor.gc_needed?

        # Try to acquire the distributed lock
        return unless @task_monitor.acquire_gc_lock

        begin
          count = @task_monitor.cleanup_orphaned_requests(@config.orphan_threshold, @config.logger)

          if count > 0
            @config.logger&.info("[Sidekiq::AsyncHttp] Garbage collection: re-enqueued #{count} orphaned requests")
          end

          # Record this GC run to coordinate with other processes
          @task_monitor.record_gc_run
        ensure
          @task_monitor.release_gc_lock
        end
      rescue => e
        @config.logger&.error("[Sidekiq::AsyncHttp] Garbage collection failed: #{e.class} - #{e.message}")
        raise if AsyncHttp.testing?
      end
    end
  end
end
