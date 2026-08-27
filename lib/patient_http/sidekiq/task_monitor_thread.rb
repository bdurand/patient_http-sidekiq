# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Background thread that maintains heartbeats and performs garbage collection
    # for in-flight HTTP requests.
    class TaskMonitorThread
      include PatientHttp::TimeHelper

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
      # @param tracked_ids_callback [Proc] callback to get the IDs of all requests the
      #   processors are tracking (queued, pending, and in-flight)
      # @param stats [Stats, nil] stats aggregator to flush on the monitor cadence
      # @return [void]
      def initialize(config, task_monitor, tracked_ids_callback, stats: nil)
        @config = config
        @task_monitor = task_monitor
        @tracked_ids_callback = tracked_ids_callback
        @stats = stats
        @thread = nil
        @running = Concurrent::AtomicBoolean.new(false)
        @stop_signal = Concurrent::Event.new
      end

      # Start the monitor thread.
      #
      # @return [void]
      def start
        return unless @running.make_true
        @stop_signal.reset

        @task_monitor.ping_process

        @thread = Thread.new do
          run
        rescue => e
          # Log error but don't crash
          @config.logger&.error("[PatientHttp::Sidekiq] Monitor error: #{e.message}\n#{e.backtrace.join("\n")}")
          raise if PatientHttp.testing?
        end

        @thread.name = "patient-http-monitor"
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
        @config.logger&.info("[PatientHttp::Sidekiq] Monitor thread started")

        # Route Sidekiq client pushes made from this thread (orphan
        # re-enqueues) through the gem's dedicated Redis pool.
        gem_pool = PatientHttp::Sidekiq.redis_pool
        Thread.current[:sidekiq_redis_pool] = gem_pool.pool if gem_pool

        last_heartbeat_update = monotonic_time - @config.heartbeat_interval
        last_gc_attempt = monotonic_time - @config.heartbeat_interval

        loop do
          break unless @running.true?

          current_time = monotonic_time

          # Publish this process's capacity on every pass. It is a single
          # round trip, and the Web UI reports the inflight counts it carries,
          # which would otherwise be a full heartbeat interval old.
          ping_process

          # Update heartbeats for all inflight requests
          if current_time - last_heartbeat_update >= @config.heartbeat_interval
            update_heartbeats
            last_heartbeat_update = current_time
          end

          # Attempt garbage collection
          if current_time - last_gc_attempt >= @config.heartbeat_interval
            attempt_garbage_collection
            last_gc_attempt = current_time
          end

          flush_stats

          # Sleep with interruptible wait - returns true if interrupted
          wait_time = @config.heartbeat_interval / 2.0
          wait_time = MAX_MONITOR_SLEEP if wait_time > MAX_MONITOR_SLEEP
          @stop_signal.wait(wait_time)
        end

        @config.logger&.info("[PatientHttp::Sidekiq] Monitor thread stopped")
      end

      # Register this process and publish its capacity.
      #
      # @return [void]
      def ping_process
        @task_monitor.ping_process
      rescue => e
        @config.logger&.error("[PatientHttp::Sidekiq] Failed to register the process: #{e.class} - #{e.message}")
        raise if PatientHttp.testing?
      end

      # Flush locally aggregated stats when their interval has elapsed.
      #
      # @return [void]
      def flush_stats
        @stats&.flush_if_due
      rescue => e
        @config.logger&.error("[PatientHttp::Sidekiq] Failed to flush stats: #{e.class} - #{e.message}")
        raise if PatientHttp.testing?
      end

      # Update heartbeats for all tracked requests.
      #
      # @return [void]
      def update_heartbeats
        request_ids = @tracked_ids_callback.call
        return if request_ids.empty?

        @task_monitor.update_heartbeats(request_ids)

        @config.logger&.debug("[PatientHttp::Sidekiq] Updated heartbeats for #{request_ids.size} tracked requests")
      rescue => e
        @config.logger&.error("[PatientHttp::Sidekiq] Failed to update heartbeats: #{e.class} - #{e.message}")
        raise if PatientHttp.testing?
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
            @config.logger&.info("[PatientHttp::Sidekiq] Garbage collection: re-enqueued #{count} orphaned requests")
          end

          # Record this GC run to coordinate with other processes
          @task_monitor.record_gc_run
        ensure
          @task_monitor.release_gc_lock
        end
      rescue => e
        @config.logger&.error("[PatientHttp::Sidekiq] Garbage collection failed: #{e.class} - #{e.message}")
        raise if PatientHttp.testing?
      end
    end
  end
end
