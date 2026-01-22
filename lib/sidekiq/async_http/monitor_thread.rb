# frozen_string_literal: true

require "concurrent"

module Sidekiq
  module AsyncHttp
    # Background thread that maintains heartbeats and performs garbage collection
    # for in-flight HTTP requests.
    class MonitorThread
      include TimeHelper

      # Minimum seconds to sleep between monitor thread checks
      MAX_MONITOR_SLEEP = 5.0

      # @return [Configuration] the configuration object
      attr_reader :config

      # @return [InflightRegistry] the inflight request registry
      attr_reader :inflight_registry

      # Initialize the monitor thread.
      #
      # @param config [Configuration] the configuration object
      # @param inflight_registry [InflightRegistry] the inflight request registry
      # @param inflight_ids_callback [Proc] callback to get current inflight request IDs
      # @return [void]
      def initialize(config, inflight_registry, inflight_ids_callback)
        @config = config
        @inflight_registry = inflight_registry
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

        @thread = Thread.new do
          Thread.current.name = "async-http-monitor"
          run
        rescue => e
          # Log error but don't crash
          @config.logger&.error("[Sidekiq::AsyncHttp] Monitor error: #{e.message}\n#{e.backtrace.join("\n")}")
          raise if AsyncHttp.testing?
        end
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

        @inflight_registry.update_heartbeats(request_ids)

        @config.logger&.debug("[Sidekiq::AsyncHttp] Updated heartbeats for #{request_ids.size} inflight requests")
      rescue => e
        @config.logger&.error("[Sidekiq::AsyncHttp] Failed to update heartbeats: #{e.class} - #{e.message}")
        raise if AsyncHttp.testing?
      end

      # Attempt to acquire GC lock and clean up orphaned requests.
      #
      # @return [void]
      def attempt_garbage_collection
        # Try to acquire the distributed lock
        return unless @inflight_registry.acquire_gc_lock

        begin
          count = @inflight_registry.cleanup_orphaned_requests(@config.orphan_threshold, @config.logger)

          if count > 0
            @config.logger&.info("[Sidekiq::AsyncHttp] Garbage collection: re-enqueued #{count} orphaned requests")
          end
        ensure
          @inflight_registry.release_gc_lock
        end
      rescue => e
        @config.logger&.error("[Sidekiq::AsyncHttp] Garbage collection failed: #{e.class} - #{e.message}")
        raise if AsyncHttp.testing?
      end
    end
  end
end
