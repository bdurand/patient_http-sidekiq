# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Background thread that updates heartbeats for in-flight requests and
    # re-enqueues orphaned requests. The thread also publishes this process's
    # capacity and flushes stats.
    class TaskMonitorThread
      include PatientHttp::TimeHelper

      # The maximum number of seconds to sleep between monitor passes.
      MAX_MONITOR_SLEEP = 5.0

      # @return [Configuration] The gem configuration.
      attr_reader :config

      # @return [TaskMonitor] The in-flight request registry.
      attr_reader :task_monitor

      # Creates a monitor thread. The thread doesn't run until {#start} is
      # called.
      #
      # @param config [Configuration] The gem configuration.
      # @param task_monitor [TaskMonitor] The in-flight request registry.
      # @param tracked_ids_callback [Proc] A callable that returns the IDs of
      #   all requests that the processors track: queued, pending, and in
      #   flight.
      # @param stats [Stats, nil] The stats aggregator to flush on each pass.
      def initialize(config, task_monitor, tracked_ids_callback, stats: nil)
        @config = config
        @task_monitor = task_monitor
        @tracked_ids_callback = tracked_ids_callback
        @stats = stats
        @thread = nil
        @running = Concurrent::AtomicBoolean.new(false)
        @stop_signal = Concurrent::Event.new
      end

      # Starts the thread. Has no effect if the thread is running.
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

      # Stops the thread. Waits up to 1 second for the thread to finish, and
      # then kills it.
      #
      # @return [void]
      def stop
        @running.make_false
        @stop_signal.set  # Interrupt the sleep immediately
        @thread&.join(1)
        @thread&.kill if @thread&.alive?
        @thread = nil
      end

      # Returns whether the thread is running.
      #
      # @return [Boolean] +true+ if the thread is running.
      def running?
        @running.true?
      end

      private

      # Runs the monitor loop until the thread is stopped.
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

      # Registers this process and publishes its capacity.
      #
      # @return [void]
      def ping_process
        @task_monitor.ping_process
      rescue => e
        @config.logger&.error("[PatientHttp::Sidekiq] Failed to register the process: #{e.class} - #{e.message}")
        raise if PatientHttp.testing?
      end

      # Flushes local stats if the flush interval has passed.
      #
      # @return [void]
      def flush_stats
        @stats&.flush_if_due
      rescue => e
        @config.logger&.error("[PatientHttp::Sidekiq] Failed to flush stats: #{e.class} - #{e.message}")
        raise if PatientHttp.testing?
      end

      # Updates the heartbeats of all tracked requests.
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

      # Re-enqueues orphaned requests if garbage collection is due and this
      # process gets the garbage collection lock.
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
