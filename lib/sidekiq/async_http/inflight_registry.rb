# frozen_string_literal: true

require "json"
require "socket"
require "securerandom"

module Sidekiq
  module AsyncHttp
    # Manages inflight request tracking in Redis for crash recovery.
    #
    # This class maintains a sorted set of request IDs indexed by timestamp
    # and a hash of request payloads. It provides distributed locking for
    # orphan detection and automatic re-enqueuing of requests that were
    # interrupted by process crashes.
    class InflightRegistry
      # Redis key prefixes
      INFLIGHT_INDEX_KEY = "sidekiq:async_http:inflight_index"
      INFLIGHT_JOBS_KEY = "sidekiq:async_http:inflight_jobs"
      GC_LOCK_KEY = "sidekiq:async_http:gc_lock"

      # @return [Configuration] the configuration object
      attr_reader :config

      # Initialize the registry.
      #
      # @param config [Configuration] the configuration object
      #
      # @return [void]
      def initialize(config)
        @config = config
        @hostname = ::Socket.gethostname.force_encoding("UTF-8").freeze
        @pid = ::Process.pid
        @lock_identifier = "#{@hostname}:#{@pid}:#{SecureRandom.hex(8)}".freeze
      end

      # Register a request as inflight in Redis.
      #
      # @param task [RequestTask] the request task to register
      #
      # @return [void]
      def register(task)
        timestamp_ms = (Time.now.to_f * 1000).round
        job_payload = task.sidekiq_job.to_json

        Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.zadd(INFLIGHT_INDEX_KEY, timestamp_ms, task.id)
            transaction.hset(INFLIGHT_JOBS_KEY, task.id, job_payload)
            transaction.expire(INFLIGHT_INDEX_KEY, inflight_ttl)
            transaction.expire(INFLIGHT_JOBS_KEY, inflight_ttl)
          end
        end
      end

      # Unregister a request from Redis (called when request completes).
      #
      # @param request_id [String] the request ID to unregister
      #
      # @return [void]
      def unregister(request_id)
        Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.zrem(INFLIGHT_INDEX_KEY, request_id)
            transaction.hdel(INFLIGHT_JOBS_KEY, request_id)
          end
        end
      end

      # Update the heartbeat timestamp for a request.
      #
      # @param request_id [String] the request ID to update
      #
      # @return [void]
      def update_heartbeat(request_id)
        timestamp_ms = (Time.now.to_f * 1000).round

        Sidekiq.redis do |redis|
          redis.zadd(INFLIGHT_INDEX_KEY, timestamp_ms, request_id)
        end
      end

      # Update heartbeat timestamps for multiple requests in a single operation.
      #
      # @param request_ids [Array<String>] the request IDs to update
      #
      # @return [void]
      def update_heartbeats(request_ids)
        return if request_ids.empty?

        timestamp_ms = (Time.now.to_f * 1000).round

        Sidekiq.redis do |redis|
          redis.pipelined do |pipeline|
            request_ids.each do |request_id|
              pipeline.zadd(INFLIGHT_INDEX_KEY, timestamp_ms, request_id)
            end
          end
        end
      end

      # Try to acquire the distributed garbage collection lock.
      #
      # @return [Boolean] true if lock acquired, false otherwise
      def acquire_gc_lock
        Sidekiq.redis do |redis|
          # Use SET with NX and EX options directly
          # Returns "OK" if successful with Sidekiq.redis, nil if key already exists
          !!redis.set(GC_LOCK_KEY, @lock_identifier, nx: true, ex: gc_lock_ttl)
        end
      end

      # Release the garbage collection lock if held by this process.
      #
      # Uses Redis WATCH/MULTI/EXEC for optimistic locking to ensure we only
      # delete the lock if it's still held by this process.
      #
      # @return [Boolean] true if the lock was released, false otherwise
      def release_gc_lock
        Sidekiq.redis do |redis|
          # Watch the lock key for changes
          redis.watch(GC_LOCK_KEY)

          # Get current lock value
          current_value = redis.get(GC_LOCK_KEY)

          if current_value == @lock_identifier
            # Lock is ours, delete it atomically
            result = redis.multi do |transaction|
              transaction.del(GC_LOCK_KEY)
            end
            # MULTI returns nil if transaction was aborted (someone else modified the key)
            # Otherwise returns array with results
            !result.nil?
          else
            # Lock is not ours or doesn't exist
            redis.unwatch
            false
          end
        end
      end

      # Find and re-enqueue orphaned requests.
      #
      # @param orphan_threshold_seconds [Numeric] age threshold for considering a request orphaned
      # @param logger [Logger] logger for output
      #
      # @return [Integer] number of orphaned requests re-enqueued
      def cleanup_orphaned_requests(orphan_threshold_seconds, logger)
        threshold_timestamp_ms = calculate_threshold_timestamp(orphan_threshold_seconds)
        orphaned_requests = fetch_orphaned_requests(threshold_timestamp_ms)

        return 0 if orphaned_requests.empty?

        reenqueue_orphaned_jobs(orphaned_requests, threshold_timestamp_ms, logger)
      end

      # Get the count of inflight requests in Redis.
      #
      # @return [Integer] number of inflight requests
      def inflight_count
        Sidekiq.redis do |redis|
          redis.zcard(INFLIGHT_INDEX_KEY)
        end
      end

      private

      # Calculate threshold timestamp in milliseconds for orphan detection.
      #
      # @param orphan_threshold_seconds [Numeric] age threshold in seconds
      #
      # @return [Integer] threshold timestamp in milliseconds
      def calculate_threshold_timestamp(orphan_threshold_seconds)
        ((Time.now.to_f - orphan_threshold_seconds) * 1000).round
      end

      # Fetch orphaned request IDs and their job payloads.
      #
      # @param threshold_timestamp_ms [Integer] threshold timestamp in milliseconds
      #
      # @return [Array<Array(String, String)>] array of [request_id, job_payload] pairs
      def fetch_orphaned_requests(threshold_timestamp_ms)
        # Find all requests older than the threshold
        orphaned_request_ids = Sidekiq.redis do |redis|
          redis.zrange(INFLIGHT_INDEX_KEY, "-inf", threshold_timestamp_ms, byscore: true)
        end

        return [] if orphaned_request_ids.empty?

        # Retrieve job payloads for all orphaned requests
        job_payloads = Sidekiq.redis do |redis|
          redis.hmget(INFLIGHT_JOBS_KEY, *orphaned_request_ids)
        end

        orphaned_request_ids.zip(job_payloads).reject { |_id, payload| payload.nil? }
      end

      # Re-enqueue all orphaned jobs.
      #
      # @param orphaned_requests [Array<Array(String, String)>] array of [request_id, job_payload] pairs
      # @param threshold_timestamp_ms [Integer] threshold timestamp in milliseconds
      # @param logger [Logger] logger for output
      #
      # @return [Integer] number of jobs successfully re-enqueued
      def reenqueue_orphaned_jobs(orphaned_requests, threshold_timestamp_ms, logger)
        reenqueued_count = 0

        orphaned_requests.each do |request_id, job_payload|
          if reenqueue_orphaned_job(request_id, job_payload, threshold_timestamp_ms, logger)
            reenqueued_count += 1
          end
        end

        reenqueued_count
      end

      # Re-enqueue a single orphaned job.
      #
      # @param request_id [String] the request ID
      # @param job_payload [String] the JSON job payload
      # @param threshold_timestamp_ms [Integer] threshold timestamp in milliseconds
      # @param logger [Logger] logger for output
      #
      # @return [Boolean] true if successfully re-enqueued, false otherwise
      def reenqueue_orphaned_job(request_id, job_payload, threshold_timestamp_ms, logger)
        # Check if still orphaned (heartbeat may have updated)
        return false unless still_orphaned?(request_id, threshold_timestamp_ms)

        # Remove from Redis
        remove_from_registry(request_id)

        # Re-enqueue the job
        job_hash = JSON.parse(job_payload)
        Sidekiq::Client.push(job_hash)

        logger&.info(
          "[Sidekiq::AsyncHttp] Re-enqueued orphaned request #{request_id} to #{job_hash["class"]}"
        )

        true
      rescue => e
        logger&.error(
          "[Sidekiq::AsyncHttp] Failed to re-enqueue orphaned request #{request_id}: #{e.class} - #{e.message}"
        )
        false
      end

      # Check if a request is still orphaned (timestamp hasn't been updated).
      #
      # @param request_id [String] the request ID
      # @param threshold_timestamp_ms [Integer] threshold timestamp in milliseconds
      #
      # @return [Boolean] true if still orphaned, false otherwise
      def still_orphaned?(request_id, threshold_timestamp_ms)
        current_timestamp = Sidekiq.redis do |redis|
          redis.zscore(INFLIGHT_INDEX_KEY, request_id)
        end

        current_timestamp && current_timestamp < threshold_timestamp_ms
      end

      # Remove a request from the inflight registry.
      #
      # @param request_id [String] the request ID to remove
      #
      # @return [void]
      def remove_from_registry(request_id)
        Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.zrem(INFLIGHT_INDEX_KEY, request_id)
            transaction.hdel(INFLIGHT_JOBS_KEY, request_id)
          end
        end
      end

      # Calculate the TTL for inflight data structures.
      # Should be significantly longer than the orphan threshold.
      #
      # @return [Integer] TTL in seconds
      def inflight_ttl
        # Set to 3x the orphan threshold, with a minimum of 1 hour
        [config.orphan_threshold * 3, 3600].max
      end

      # Calculate the TTL for the garbage collection lock.
      # Should be a bit longer than the heartbeat interval.
      #
      # @return [Integer] TTL in seconds
      def gc_lock_ttl
        # Set to 2x the heartbeat interval, with a minimum of 120 seconds
        [config.heartbeat_interval * 2, 120].max
      end
    end
  end
end
