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
    #
    # Task ID format: "hostname:pid:hex/request-uuid"
    # - hostname: sanitized hostname (colons and slashes replaced with dashes)
    # - pid: process ID
    # - hex: 8-character random hex for uniqueness
    # - request-uuid: unique identifier for the request
    class InflightRegistry
      # Redis key prefixes
      INFLIGHT_INDEX_KEY = "sidekiq:async_http:inflight_index"
      INFLIGHT_JOBS_KEY = "sidekiq:async_http:inflight_jobs"
      PROCESS_SET_KEY = "sidekiq:async_http:processes"
      GC_LOCK_KEY = "sidekiq:async_http:gc_lock"

      # Lua script for atomic orphan removal.
      # Checks if the task is still orphaned (timestamp < threshold) and removes it atomically.
      # This prevents race conditions where a heartbeat could update the timestamp between
      # the check and the removal.
      #
      # KEYS[1] = index key (sorted set)
      # KEYS[2] = jobs key (hash)
      # ARGV[1] = request_id
      # ARGV[2] = threshold_ms
      #
      # Returns: [removed (0/1), job_payload or nil]
      REMOVE_IF_ORPHANED_SCRIPT = <<~LUA
        local index_key = KEYS[1]
        local jobs_key = KEYS[2]
        local request_id = ARGV[1]
        local threshold_ms = tonumber(ARGV[2])

        local current_score = redis.call('ZSCORE', index_key, request_id)
        if not current_score or tonumber(current_score) >= threshold_ms then
          return {0, nil}  -- Not orphaned or already removed
        end

        local job_payload = redis.call('HGET', jobs_key, request_id)
        redis.call('ZREM', index_key, request_id)
        redis.call('HDEL', jobs_key, request_id)
        return {1, job_payload}
      LUA

      # @return [Configuration] the configuration object
      attr_reader :config

      class << self
        # Get the count of inflight requests in Redis.
        #
        # @return [Integer] number of inflight requests
        def inflight_count
          Sidekiq.redis do |redis|
            redis.zcard(INFLIGHT_INDEX_KEY)
          end
        end

        # Get all inflight counts across all processes and the number of max connections.
        #
        # @return [Hash] hash of "hostname:pid" => { inflight: Integer, max_capacity: Integer }
        def inflight_counts_by_process
          process_ids = nil
          max_connections = nil
          inflight_task_ids = nil

          Sidekiq.redis do |redis|
            process_ids = redis.smembers(PROCESS_SET_KEY)
            return {} if process_ids.empty?

            max_keys = process_ids.map { |pid| max_connections_key_for(pid) }
            max_connections = redis.mget(*max_keys)

            inflight_task_ids = redis.zrange(INFLIGHT_INDEX_KEY, 0, -1)
          end

          inflight_by_process_id = inflight_task_ids.group_by do |task_id|
            task_id.split("/", 2).first
          end

          result = {}
          stale_process_ids = []

          process_ids.zip(max_connections).each do |process_id, max_conn|
            if max_conn.nil?
              # Mark for removal if max_conn key doesn't exist (process is gone)
              stale_process_ids << process_id
            else
              host_pid = process_id.split(":", 3).first(2).join(":")
              counts = result[host_pid]
              unless counts
                counts = {inflight: 0, max_capacity: 0}
                result[host_pid] = counts
              end
              counts[:inflight] += inflight_by_process_id[process_id]&.size.to_i
              counts[:max_capacity] += max_conn.to_i
            end
          end

          # Remove stale process IDs from the set
          unless stale_process_ids.empty?
            Sidekiq.redis do |redis|
              redis.srem(PROCESS_SET_KEY, stale_process_ids)
            end
          end

          result
        end

        # Get the total max connections across all processes
        #
        # @return [Integer] sum of max connections from all active processes
        def total_max_connections
          inflight_counts_by_process.values.sum { |data| data[:max_capacity] }
        end

        # Get all registered process IDs.
        #
        # @return [Array<String>] list of process identifiers
        def registered_process_ids
          Sidekiq.redis do |redis|
            redis.smembers(PROCESS_SET_KEY)
          end
        end

        # Clear all registry data. Only allowed in test environment.
        #
        # @raise [RuntimeError] if called outside of test environment
        # @return [void]
        # @api private
        def clear_all!
          unless Sidekiq::AsyncHttp.testing?
            raise "clear_all! is only allowed in test environment"
          end

          Sidekiq.redis do |redis|
            redis.del(INFLIGHT_INDEX_KEY, INFLIGHT_JOBS_KEY, PROCESS_SET_KEY, GC_LOCK_KEY)
          end
        end

        private

        # Build the max connections key for a given process identifier.
        #
        # @param process_id [String] the process identifier
        #
        # @return [String] the Redis key for max connections
        def max_connections_key_for(process_id)
          "#{PROCESS_SET_KEY}:#{process_id}:max_connections"
        end
      end

      # @param config [Configuration] the configuration object
      def initialize(config)
        @config = config
        hostname = ::Socket.gethostname.force_encoding("UTF-8").tr(":/", "-")
        pid = ::Process.pid
        @lock_identifier = "#{hostname}:#{pid}:#{SecureRandom.hex(8)}".freeze
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
            transaction.zadd(INFLIGHT_INDEX_KEY, timestamp_ms, task_id(task))
            transaction.hset(INFLIGHT_JOBS_KEY, task_id(task), job_payload)
            transaction.expire(INFLIGHT_INDEX_KEY, inflight_ttl)
            transaction.expire(INFLIGHT_JOBS_KEY, inflight_ttl)
          end
        end
      end

      # Unregister a request from Redis (called when request completes).
      #
      # @param task [RequestTask] the request task to unregister
      #
      # @return [void]
      def unregister(task)
        Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.zrem(INFLIGHT_INDEX_KEY, task_id(task))
            transaction.hdel(INFLIGHT_JOBS_KEY, task_id(task))
          end
        end
      end

      # Remove this process's entry from the process set.
      #
      # @return [void]
      def remove_process
        Sidekiq.redis do |redis|
          redis.srem(PROCESS_SET_KEY, @lock_identifier)
          redis.del(max_connections_key)
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
              pipeline.call("ZADD", INFLIGHT_INDEX_KEY, "XX", timestamp_ms, request_id)
            end
          end
        end
      end

      # Check if a task is registered in the inflight registry.
      #
      # @param task [RequestTask] the request task
      #
      # @return [Boolean] true if registered, false otherwise
      # @api private
      def registered?(task)
        Sidekiq.redis do |redis|
          !redis.zscore(INFLIGHT_INDEX_KEY, task_id(task)).nil?
        end
      end

      # Get the heartbeat timestamp for a task.
      #
      # @param task [RequestTask] the request task
      #
      # @return [Integer, nil] timestamp in milliseconds, or nil if not registered
      # @api private
      def heartbeat_timestamp_for(task)
        score = Sidekiq.redis do |redis|
          redis.zscore(INFLIGHT_INDEX_KEY, task_id(task))
        end
        score&.to_i
      end

      # Get all registered task IDs for this registry's process.
      #
      # @return [Array<String>] list of full task IDs
      # @api private
      def registered_task_ids
        Sidekiq.redis do |redis|
          redis.zrange(INFLIGHT_INDEX_KEY, 0, -1)
        end.select { |id| id.start_with?("#{@lock_identifier}/") }
      end

      # Build unique task ID for a request task that includes process identifier.
      #
      # @param task [RequestTask] the request task
      # @return [String] the unique task ID
      def task_id(task)
        "#{@lock_identifier}/#{task.id}"
      end

      # Record the current process's max connections in Redis.
      #
      # This is used for monitoring purposes.
      #
      # @return [void]
      def ping_process
        Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.sadd(PROCESS_SET_KEY, @lock_identifier)
            transaction.set(max_connections_key, @config.max_connections)
            transaction.expire(PROCESS_SET_KEY, inflight_ttl)
            transaction.expire(max_connections_key, process_ttl)
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
        all_orphaned_request_ids = Sidekiq.redis do |redis|
          redis.zrange(INFLIGHT_INDEX_KEY, "-inf", threshold_timestamp_ms, byscore: true)
        end

        return [] if all_orphaned_request_ids.empty?

        orphaned_request_ids_by_process = all_orphaned_request_ids.group_by do |request_id|
          request_id.split("/", 2).first
        end
        all_process_ids = Sidekiq.redis do |redis|
          redis.smembers(PROCESS_SET_KEY)
        end
        orphaned_request_ids = orphaned_request_ids_by_process.except(*all_process_ids).values.flatten

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

      # Re-enqueue a single orphaned job using atomic Lua script.
      #
      # This method atomically checks if the task is still orphaned and removes it
      # in a single Redis operation, preventing race conditions where a heartbeat
      # could update the timestamp between checking and removal.
      #
      # @param request_id [String] the request ID
      # @param job_payload [String] the JSON job payload (used as fallback)
      # @param threshold_timestamp_ms [Integer] threshold timestamp in milliseconds
      # @param logger [Logger] logger for output
      #
      # @return [Boolean] true if successfully re-enqueued, false otherwise
      def reenqueue_orphaned_job(request_id, job_payload, threshold_timestamp_ms, logger)
        # Atomically check and remove if still orphaned
        removed, payload = remove_if_orphaned(request_id, threshold_timestamp_ms)

        return false unless removed == 1

        # Use payload from Lua script, fall back to provided payload
        actual_payload = payload || job_payload
        return false if actual_payload.nil?

        # Re-enqueue the job
        job_hash = JSON.parse(actual_payload)
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

      # Atomically check if orphaned and remove from registry.
      #
      # Uses a Lua script to ensure the check and removal happen in a single
      # atomic operation, preventing race conditions with heartbeat updates.
      #
      # @param request_id [String] the request ID
      # @param threshold_timestamp_ms [Integer] threshold timestamp in milliseconds
      #
      # @return [Array(Integer, String)] [removed (0/1), job_payload or nil]
      def remove_if_orphaned(request_id, threshold_timestamp_ms)
        Sidekiq.redis do |redis|
          # EVAL script numkeys key1 key2 arg1 arg2
          redis.call(
            "EVAL",
            REMOVE_IF_ORPHANED_SCRIPT,
            2, # number of keys
            INFLIGHT_INDEX_KEY,
            INFLIGHT_JOBS_KEY,
            request_id,
            threshold_timestamp_ms.to_s
          )
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

      # Calculate the TTL for the process max_connections key.
      # Must be longer than heartbeat_interval so the key survives between heartbeats.
      #
      # @return [Integer] TTL in seconds
      def process_ttl
        # Set to 2x the heartbeat interval so the key survives between heartbeats
        config.heartbeat_interval * 2
      end

      def max_connections_key
        "#{PROCESS_SET_KEY}:#{@lock_identifier}:max_connections"
      end
    end
  end
end
