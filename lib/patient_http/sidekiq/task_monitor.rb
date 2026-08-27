# frozen_string_literal: true

require "digest"
require "uri"

module PatientHttp
  module Sidekiq
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
    class TaskMonitor
      # Redis key prefixes
      INFLIGHT_INDEX_KEY = "sidekiq:patient_http:inflight_index"
      INFLIGHT_JOBS_KEY = "sidekiq:patient_http:inflight_jobs"
      INFLIGHT_DETAILS_KEY = "sidekiq:patient_http:inflight_details"
      INFLIGHT_DETAILS_INDEX_KEY = "sidekiq:patient_http:inflight_details_index"
      PROCESS_SET_KEY = "sidekiq:patient_http:processes"
      GC_LOCK_KEY = "sidekiq:patient_http:gc_lock"
      GC_LAST_RUN_KEY = "sidekiq:patient_http:gc_last_run"

      # Lua script for atomic orphan removal of a batch of request ids.
      # For each id, checks that the task is still orphaned (timestamp <
      # threshold) and removes it atomically, so a heartbeat cannot update the
      # timestamp between the check and the removal. Ids that are no longer
      # orphaned are skipped.
      #
      # KEYS[1] = index key (sorted set)
      # KEYS[2] = jobs key (hash)
      # KEYS[3] = details key (hash)
      # KEYS[4] = details index key (sorted set)
      # ARGV[1] = threshold_ms
      # ARGV[2..] = request_ids
      #
      # Every removed id is returned, even when the jobs hash no longer holds
      # its payload, so the caller can fall back to the payload it read before
      # the script ran instead of losing the request.
      #
      # Returns: flat array of [request_id, job_payload, request_id, job_payload, ...]
      #   where job_payload is nil when the hash entry was already gone
      REMOVE_IF_ORPHANED_SCRIPT = <<~LUA
        local index_key = KEYS[1]
        local jobs_key = KEYS[2]
        local details_key = KEYS[3]
        local details_index_key = KEYS[4]
        local threshold_ms = tonumber(ARGV[1])
        local removed = {}

        for i = 2, #ARGV do
          local request_id = ARGV[i]
          local current_score = redis.call('ZSCORE', index_key, request_id)
          if current_score and tonumber(current_score) < threshold_ms then
            local job_payload = redis.call('HGET', jobs_key, request_id)
            redis.call('ZREM', index_key, request_id)
            redis.call('HDEL', jobs_key, request_id)
            redis.call('ZREM', details_index_key, request_id)
            redis.call('HDEL', details_key, request_id)
            table.insert(removed, request_id)
            table.insert(removed, job_payload)
          end
        end

        return removed
      LUA
      REMOVE_IF_ORPHANED_SHA = Digest::SHA1.hexdigest(REMOVE_IF_ORPHANED_SCRIPT).freeze

      # Lua script for releasing the GC lock only when this process still owns
      # it: a single-round-trip compare-and-delete.
      #
      # KEYS[1] = lock key
      # ARGV[1] = lock identifier
      #
      # Returns: 1 if the lock was released, 0 otherwise
      RELEASE_LOCK_SCRIPT = <<~LUA
        if redis.call('GET', KEYS[1]) == ARGV[1] then
          return redis.call('DEL', KEYS[1])
        else
          return 0
        end
      LUA
      RELEASE_LOCK_SHA = Digest::SHA1.hexdigest(RELEASE_LOCK_SCRIPT).freeze

      # Number of orphaned request ids processed per Lua call.
      ORPHAN_BATCH_SIZE = 100

      # Longest URL recorded for the Web UI, so that one enormous URL cannot
      # take a disproportionate amount of memory.
      MAX_DISPLAY_URL_LENGTH = 500

      # @return [Configuration] the configuration object
      attr_reader :config

      class << self
        # Get the count of inflight requests in Redis.
        #
        # @return [Integer] number of inflight requests
        def inflight_count
          ::Sidekiq.redis do |redis|
            redis.zcard(INFLIGHT_INDEX_KEY)
          end
        end

        # Get all inflight counts across all processes and the number of max connections.
        #
        # The per-process inflight count comes from the shared inflight index, so
        # it includes requests left behind by processes that have since died. The
        # nested per-processor counts are snapshots each process publishes with
        # its heartbeat, so they only cover processes that are still running and
        # can lag by up to one monitor cycle.
        #
        # @return [Hash] hash of "hostname:pid" =>
        #   { inflight: Integer, max_capacity: Integer,
        #     processors: { String => { inflight: Integer, max_capacity: Integer } } }
        def inflight_counts_by_process
          process_ids = nil
          max_connections = nil
          processor_snapshots = nil
          inflight_task_ids = nil

          ::Sidekiq.redis do |redis|
            process_ids = redis.smembers(PROCESS_SET_KEY)
            return {} if process_ids.empty?

            max_keys = process_ids.map { |pid| max_connections_key_for(pid) }
            processor_keys = process_ids.map { |pid| processors_key_for(pid) }
            values = redis.mget(*max_keys, *processor_keys)
            max_connections = values.first(process_ids.size)
            processor_snapshots = values.last(process_ids.size)

            inflight_task_ids = redis.zrange(INFLIGHT_INDEX_KEY, 0, -1)
          end

          inflight_by_process_id = inflight_task_ids.group_by do |task_id|
            task_id.split("/", 2).first
          end

          result = {}
          stale_process_ids = []

          process_ids.zip(max_connections, processor_snapshots).each do |process_id, max_conn, snapshot|
            if max_conn.nil?
              # Mark for removal if max_conn key doesn't exist (process is gone)
              stale_process_ids << process_id
            else
              host_pid = process_id.split(":", 3).first(2).join(":")
              counts = result[host_pid]
              unless counts
                counts = {inflight: 0, max_capacity: 0, processors: {}}
                result[host_pid] = counts
              end
              counts[:inflight] += inflight_by_process_id[process_id]&.size.to_i
              counts[:max_capacity] += max_conn.to_i
              merge_processor_snapshot(counts[:processors], snapshot)
            end
          end

          # Remove stale process IDs from the set
          unless stale_process_ids.empty?
            ::Sidekiq.redis do |redis|
              redis.srem(PROCESS_SET_KEY, stale_process_ids)
            end
          end

          result
        end

        # Get the inflight and capacity counts for each named processor across
        # all running processes.
        #
        # @param processes [Hash, nil] the result of {inflight_counts_by_process};
        #   read from Redis when not given
        # @return [Hash] hash of processor name => { inflight: Integer, max_capacity: Integer }
        def inflight_counts_by_processor(processes = nil)
          processes ||= inflight_counts_by_process

          result = {}
          processes.each_value do |data|
            merge_processor_counts(result, data[:processors])
          end
          result.sort.to_h
        end

        # Get the details of the requests that have been in flight the longest.
        #
        # Only requests registered while +inflight_details+ was enabled are
        # reported. A request stays listed while its crash-recovery record
        # exists, so a request left behind by a process that died is listed
        # until the orphan collector re-enqueues it.
        #
        # @param limit [Integer] maximum number of requests to return
        # @return [Array<Hash>] oldest first, each with :request_id, :process_id,
        #   :url, :http_method, :processor, and :age in seconds
        def inflight_details(limit: 50)
          return [] if limit <= 0

          task_ids = nil
          timestamps = nil
          records = nil

          ::Sidekiq.redis do |redis|
            entries = redis.zrange(INFLIGHT_DETAILS_INDEX_KEY, 0, limit - 1, withscores: true)
            return [] if entries.empty?

            task_ids = entries.map(&:first)
            timestamps = entries.map(&:last)
            records = redis.hmget(INFLIGHT_DETAILS_KEY, *task_ids)
          end

          now = Time.now.to_f
          task_ids.zip(timestamps, records).filter_map do |task_id, timestamp_ms, record|
            details = parse_details(record)
            next unless details

            process_id, request_id = task_id.split("/", 2)
            {
              request_id: request_id,
              process_id: process_id.to_s.split(":", 3).first(2).join(":"),
              url: details["url"],
              http_method: details["method"],
              processor: details["processor"],
              age: (now - timestamp_ms.to_f / 1000.0).round(1)
            }
          end
        end

        # Remove the user name, password, query string, and fragment from a URL,
        # keeping the scheme, host, and path. Used unless the configuration
        # names its own sanitizer.
        #
        # @param url [String] the request URL
        # @return [String] the URL to display
        def sanitize_url(url)
          uri = URI.parse(url.to_s)
          uri.query = nil
          uri.fragment = nil
          # The password must be cleared before the user, and clearing the user
          # info in one step does nothing.
          uri.password = nil if uri.respond_to?(:password=)
          uri.user = nil if uri.respond_to?(:user=)
          uri.to_s
        rescue
          # A URL that cannot be parsed, such as one with a character outside
          # US-ASCII, still must not carry credentials or a query string.
          strip_credentials(url.to_s.split(/[?#]/, 2).first.to_s)
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
          ::Sidekiq.redis do |redis|
            redis.smembers(PROCESS_SET_KEY)
          end
        end

        # Clear all registry data. Only allowed in test environment.
        #
        # @raise [RuntimeError] if called outside of test environment
        # @return [void]
        # @api private
        def clear_all!
          unless PatientHttp.testing?
            raise "clear_all! is only allowed in test environment"
          end

          ::Sidekiq.redis do |redis|
            redis.del(
              INFLIGHT_INDEX_KEY, INFLIGHT_JOBS_KEY, INFLIGHT_DETAILS_KEY,
              INFLIGHT_DETAILS_INDEX_KEY, PROCESS_SET_KEY, GC_LOCK_KEY, GC_LAST_RUN_KEY
            )
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

        # Build the per-processor snapshot key for a given process identifier.
        #
        # @param process_id [String] the process identifier
        #
        # @return [String] the Redis key for the per-processor snapshot
        def processors_key_for(process_id)
          "#{PROCESS_SET_KEY}:#{process_id}:processors"
        end

        # Remove anything between the scheme and the host of a URL.
        #
        # @param url [String] the URL
        # @return [String] the URL without credentials
        def strip_credentials(url)
          url.sub(%r{\A([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]*@}, '\\1')
        end

        # Parse one stored details record, ignoring one that cannot be read.
        #
        # @param record [String, nil] the serialized record
        # @return [Hash, nil] the parsed record
        def parse_details(record)
          return nil if record.nil?

          details = JSON.parse(record)
          details.is_a?(Hash) ? details : nil
        rescue JSON::ParserError
          nil
        end

        # Merge one process's published snapshot into a set of per-processor counts.
        #
        # A snapshot written by a process running a different version of the gem
        # may not be readable; it is skipped rather than failing the whole report.
        #
        # @param counts [Hash] per-processor counts to merge into
        # @param snapshot [String, nil] the serialized snapshot
        #
        # @return [void]
        def merge_processor_snapshot(counts, snapshot)
          return if snapshot.nil?

          parsed = begin
            JSON.parse(snapshot)
          rescue JSON::ParserError
            return
          end
          return unless parsed.is_a?(Hash)

          merge_processor_counts(
            counts,
            parsed.transform_values do |values|
              next {} unless values.is_a?(Hash)

              {inflight: values["inflight"].to_i, max_capacity: values["max_capacity"].to_i}
            end
          )
        end

        # Add per-processor counts into an accumulator.
        #
        # @param counts [Hash] per-processor counts to merge into
        # @param additions [Hash, nil] per-processor counts to add
        #
        # @return [void]
        def merge_processor_counts(counts, additions)
          additions&.each do |name, values|
            totals = (counts[name] ||= {inflight: 0, max_capacity: 0})
            totals[:inflight] += values[:inflight].to_i
            totals[:max_capacity] += values[:max_capacity].to_i
          end
        end
      end

      # @param config [Configuration] the configuration object
      # @param max_connections [#call, nil] callable returning the process's total
      #   configured max connections; defaults to the configuration's value. Ignored
      #   when a +processors+ source is given, which carries the same information
      #   per processor.
      # @param processors [#call, nil] callable returning a snapshot of the
      #   process's processors as a hash of name => { inflight:, max_capacity: }.
      #   The snapshot is published with each heartbeat so the Web UI can report
      #   capacity per processor.
      def initialize(config, max_connections: nil, processors: nil)
        @config = config
        @max_connections_source = max_connections || -> { config.max_connections }
        @processors_source = processors
        hostname = ::Socket.gethostname.force_encoding("UTF-8").tr(":/", "-")
        pid = ::Process.pid
        @lock_identifier = "#{hostname}:#{pid}:#{SecureRandom.hex(8)}".freeze
      end

      # Register a request as inflight in Redis.
      #
      # @param task [RequestTask] the request task to register
      # @param processor_name [Symbol, String, nil] name of the processor running
      #   the request, recorded with the request details
      #
      # @return [void]
      def register(task, processor_name: nil)
        timestamp_ms = (Time.now.to_f * 1000).round
        job_payload = JSON.generate(task.task_handler.sidekiq_job)
        task_id = full_task_id(task.id)
        details = request_details(task, processor_name)

        PatientHttp::Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.zadd(INFLIGHT_INDEX_KEY, timestamp_ms, task_id)
            transaction.hset(INFLIGHT_JOBS_KEY, task_id, job_payload)
            transaction.expire(INFLIGHT_INDEX_KEY, inflight_ttl)
            transaction.expire(INFLIGHT_JOBS_KEY, inflight_ttl)
            if details
              transaction.zadd(INFLIGHT_DETAILS_INDEX_KEY, timestamp_ms, task_id)
              transaction.hset(INFLIGHT_DETAILS_KEY, task_id, details)
              transaction.expire(INFLIGHT_DETAILS_INDEX_KEY, inflight_ttl)
              transaction.expire(INFLIGHT_DETAILS_KEY, inflight_ttl)
            end
          end
        end
      end

      # Unregister a request from Redis (called when request completes).
      #
      # @param task [RequestTask] the request task to unregister
      #
      # @return [void]
      def unregister(task)
        task_id = full_task_id(task.id)

        PatientHttp::Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.zrem(INFLIGHT_INDEX_KEY, task_id)
            transaction.hdel(INFLIGHT_JOBS_KEY, task_id)
            transaction.zrem(INFLIGHT_DETAILS_INDEX_KEY, task_id)
            transaction.hdel(INFLIGHT_DETAILS_KEY, task_id)
          end
        end
      end

      # Remove this process's entry from the process set.
      #
      # @return [void]
      def remove_process
        PatientHttp::Sidekiq.redis do |redis|
          redis.pipelined do |pipeline|
            pipeline.srem(PROCESS_SET_KEY, @lock_identifier)
            pipeline.del(max_connections_key)
            pipeline.del(processors_key)
          end
        end
      end

      # Update heartbeat timestamps for multiple requests in a single operation.
      #
      # @param task_ids [Array<String>] the request IDs to update
      #
      # @return [void]
      def update_heartbeats(task_ids)
        return if task_ids.empty?

        timestamp_ms = (Time.now.to_f * 1000).round

        PatientHttp::Sidekiq.redis do |redis|
          redis.pipelined do |pipeline|
            task_ids.each do |task_id|
              pipeline.call("ZADD", INFLIGHT_INDEX_KEY, "XX", timestamp_ms, full_task_id(task_id))
            end
            # Keep the inflight keys alive while requests are still in flight;
            # otherwise they only get their TTL refreshed when new requests
            # are registered.
            pipeline.call("EXPIRE", INFLIGHT_INDEX_KEY, inflight_ttl)
            pipeline.call("EXPIRE", INFLIGHT_JOBS_KEY, inflight_ttl)
            pipeline.call("EXPIRE", INFLIGHT_DETAILS_INDEX_KEY, inflight_ttl)
            pipeline.call("EXPIRE", INFLIGHT_DETAILS_KEY, inflight_ttl)
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
        PatientHttp::Sidekiq.redis do |redis|
          !redis.zscore(INFLIGHT_INDEX_KEY, full_task_id(task.id)).nil?
        end
      end

      # Get the heartbeat timestamp for a task.
      #
      # @param task [RequestTask] the request task
      #
      # @return [Integer, nil] timestamp in milliseconds, or nil if not registered
      # @api private
      def heartbeat_timestamp_for(task)
        score = PatientHttp::Sidekiq.redis do |redis|
          redis.zscore(INFLIGHT_INDEX_KEY, full_task_id(task.id))
        end
        score&.to_i
      end

      # Get all registered task IDs for this registry's process.
      #
      # @return [Array<String>] list of full task IDs
      # @api private
      def registered_task_ids
        PatientHttp::Sidekiq.redis do |redis|
          redis.zrange(INFLIGHT_INDEX_KEY, 0, -1)
        end.select { |id| id.start_with?("#{@lock_identifier}/") }
      end

      # Build unique task ID for a request task that includes process identifier.
      #
      # @param task_id [String] the request task
      # @return [String] the unique task ID
      def full_task_id(task_id)
        "#{@lock_identifier}/#{task_id}"
      end

      # Record the current process's capacity in Redis.
      #
      # This is used for monitoring purposes. The max connections key doubles as
      # the process's liveness marker: it is refreshed on every heartbeat with a
      # TTL shorter than the process set's, so a member of the set whose key has
      # expired belongs to a process that is gone.
      #
      # @return [void]
      def ping_process
        snapshot = @processors_source&.call
        max_connections = if snapshot
          snapshot.values.sum { |counts| counts[:max_capacity].to_i }
        else
          @max_connections_source.call
        end

        PatientHttp::Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.sadd(PROCESS_SET_KEY, @lock_identifier)
            transaction.set(max_connections_key, max_connections)
            transaction.expire(PROCESS_SET_KEY, inflight_ttl)
            transaction.expire(max_connections_key, process_ttl)
            if snapshot
              transaction.set(processors_key, serialize_processor_snapshot(snapshot), ex: process_ttl)
            end
          end
        end
      end

      # Try to acquire the distributed garbage collection lock.
      #
      # @return [Boolean] true if lock acquired, false otherwise
      def acquire_gc_lock
        PatientHttp::Sidekiq.redis do |redis|
          # Use SET with NX and EX options directly
          # Returns "OK" if successful, nil if key already exists
          !!redis.set(GC_LOCK_KEY, @lock_identifier, nx: true, ex: gc_lock_ttl)
        end
      end

      # Release the garbage collection lock if held by this process.
      #
      # Uses a compare-and-delete Lua script so the check and deletion happen
      # atomically in a single round trip.
      #
      # @return [Boolean] true if the lock was released, false otherwise
      def release_gc_lock
        result = PatientHttp::Sidekiq.redis do |redis|
          run_script(redis, RELEASE_LOCK_SCRIPT, RELEASE_LOCK_SHA, [GC_LOCK_KEY], [@lock_identifier])
        end
        result == 1
      end

      # Check if garbage collection should run based on the last run timestamp.
      #
      # Returns true if the GC_LAST_RUN_KEY doesn't exist in Redis or if enough
      # time has elapsed since the last GC run.
      #
      # @return [Boolean] true if GC should run, false otherwise
      def gc_needed?
        last_run = PatientHttp::Sidekiq.redis do |redis|
          redis.get(GC_LAST_RUN_KEY)
        end

        return true if last_run.nil?

        last_run_time = Time.at(last_run.to_f / 1000.0)
        Time.now - last_run_time >= config.heartbeat_interval
      end

      # Record the timestamp of the last GC run in Redis.
      #
      # The timestamp is stored with a TTL slightly longer than the heartbeat
      # interval to coordinate GC execution across multiple processes.
      #
      # @return [void]
      def record_gc_run
        PatientHttp::Sidekiq.redis do |redis|
          redis.set(GC_LAST_RUN_KEY, (Time.now.to_f * 1000).floor, ex: gc_last_run_ttl)
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
        all_orphaned_request_ids = PatientHttp::Sidekiq.redis do |redis|
          redis.zrange(INFLIGHT_INDEX_KEY, "-inf", threshold_timestamp_ms, byscore: true)
        end

        return [] if all_orphaned_request_ids.empty?

        orphaned_request_ids_by_process = all_orphaned_request_ids.group_by do |request_id|
          request_id.split("/", 2).first
        end
        live_process_ids = prune_stale_processes(orphaned_request_ids_by_process.keys)
        orphaned_request_ids = orphaned_request_ids_by_process.except(*live_process_ids).values.flatten

        return [] if orphaned_request_ids.empty?

        # Retrieve job payloads for all orphaned requests
        job_payloads = PatientHttp::Sidekiq.redis do |redis|
          redis.hmget(INFLIGHT_JOBS_KEY, *orphaned_request_ids)
        end

        orphaned_request_ids.zip(job_payloads).reject { |_id, payload| payload.nil? }
      end

      # Determine which of the given process IDs belong to live processes,
      # removing dead ones from the process set.
      #
      # Membership in the process set alone doesn't prove liveness: a crashed
      # process never removes itself from the set. A process is only considered
      # live if its max_connections key (refreshed on every heartbeat with a
      # short TTL) still exists. Stale members are removed from the set so
      # their inflight requests can be recovered.
      #
      # @param process_ids [Array<String>] candidate process IDs
      #
      # @return [Array<String>] the subset of process IDs that are live
      def prune_stale_processes(process_ids)
        registered_ids = PatientHttp::Sidekiq.redis do |redis|
          redis.smembers(PROCESS_SET_KEY)
        end
        candidates = process_ids & registered_ids
        return [] if candidates.empty?

        max_connection_values = PatientHttp::Sidekiq.redis do |redis|
          redis.mget(*candidates.map { |process_id| max_connections_key_for(process_id) })
        end

        stale_process_ids, live_process_ids = candidates.zip(max_connection_values)
          .partition { |_process_id, max_conn| max_conn.nil? }
          .map { |pairs| pairs.map(&:first) }

        unless stale_process_ids.empty?
          PatientHttp::Sidekiq.redis do |redis|
            redis.srem(PROCESS_SET_KEY, stale_process_ids)
          end
        end

        live_process_ids
      end

      # Re-enqueue all orphaned jobs.
      #
      # Ids are processed in batches: each batch is atomically checked and
      # removed in one Lua call, then the removed jobs are pushed back to
      # Sidekiq one by one (preserving each job's class, queue, and jid).
      #
      # @param orphaned_requests [Array<Array(String, String)>] array of [request_id, job_payload] pairs
      # @param threshold_timestamp_ms [Integer] threshold timestamp in milliseconds
      # @param logger [Logger] logger for output
      #
      # @return [Integer] number of jobs successfully re-enqueued
      def reenqueue_orphaned_jobs(orphaned_requests, threshold_timestamp_ms, logger)
        reenqueued_count = 0
        # Payloads read before the script ran, used when the jobs hash entry
        # was removed between the read and the script.
        known_payloads = orphaned_requests.to_h

        orphaned_requests.map(&:first).each_slice(ORPHAN_BATCH_SIZE) do |request_ids|
          removed = remove_if_orphaned(request_ids, threshold_timestamp_ms)

          removed.each_slice(2) do |request_id, job_payload|
            job_payload ||= known_payloads[request_id]
            next if job_payload.nil?

            begin
              job_hash = JSON.parse(job_payload)
              ::Sidekiq::Client.push(job_hash)
              reenqueued_count += 1

              logger&.info(
                "[PatientHttp::Sidekiq] Re-enqueued orphaned request #{request_id} to #{job_hash["class"]}"
              )
            rescue => e
              logger&.error(
                "[PatientHttp::Sidekiq] Failed to re-enqueue orphaned request #{request_id}: #{e.class} - #{e.message}"
              )
            end
          end
        end

        reenqueued_count
      end

      # Atomically check a batch of ids and remove the ones still orphaned.
      #
      # Uses a Lua script so the check and removal happen in a single atomic
      # operation, preventing race conditions with heartbeat updates.
      #
      # @param request_ids [Array<String>] the request IDs to check
      # @param threshold_timestamp_ms [Integer] threshold timestamp in milliseconds
      #
      # @return [Array<String>] flat array of [request_id, job_payload, ...] pairs
      def remove_if_orphaned(request_ids, threshold_timestamp_ms)
        PatientHttp::Sidekiq.redis do |redis|
          run_script(
            redis,
            REMOVE_IF_ORPHANED_SCRIPT,
            REMOVE_IF_ORPHANED_SHA,
            [INFLIGHT_INDEX_KEY, INFLIGHT_JOBS_KEY, INFLIGHT_DETAILS_KEY, INFLIGHT_DETAILS_INDEX_KEY],
            [threshold_timestamp_ms.to_s, *request_ids]
          )
        end
      end

      # Run a Lua script by its SHA, falling back to a full EVAL (which also
      # loads the script into the server's cache) when the server does not
      # know the script yet.
      #
      # @param redis [Object] the Redis connection
      # @param script [String] the Lua source
      # @param sha [String] the precomputed SHA1 of the source
      # @param keys [Array<String>] script KEYS
      # @param argv [Array<String>] script ARGV
      # @return [Object] the script's return value
      def run_script(redis, script, sha, keys, argv)
        redis.call("EVALSHA", sha, keys.size, *keys, *argv)
      rescue RedisClient::CommandError => e
        raise unless e.message.include?("NOSCRIPT")

        redis.call("EVAL", script, keys.size, *keys, *argv)
      end

      # Build the serialized details recorded for a request, or nil when the
      # details are turned off or cannot be built. A failure here must not stop
      # the request from being registered, so it is logged and skipped.
      #
      # @param task [RequestTask] the request task
      # @param processor_name [Symbol, String, nil] the processor running the request
      # @return [String, nil] the serialized details
      def request_details(task, processor_name)
        return nil unless config.inflight_details?

        request = task.request
        JSON.generate({
          "url" => display_url(request.url),
          "method" => request.http_method.to_s,
          "processor" => processor_name&.to_s
        }.compact)
      rescue => e
        config.logger&.warn(
          "[PatientHttp::Sidekiq] Failed to record the details of request #{task.id}: #{e.class} - #{e.message}"
        )
        nil
      end

      # The URL to record for a request, sanitized and bounded in length.
      #
      # @param url [String] the request URL
      # @return [String] the URL to display
      def display_url(url)
        sanitizer = config.inflight_url_sanitizer
        sanitized = sanitizer ? sanitizer.call(url) : self.class.sanitize_url(url)
        sanitized.to_s[0, MAX_DISPLAY_URL_LENGTH]
      end

      # Calculate the TTL for inflight data structures.
      # Should be significantly longer than the orphan threshold.
      #
      # @return [Integer] TTL in seconds
      def inflight_ttl
        # Set to 3x the orphan threshold, with a minimum of 1 hour
        [config.orphan_threshold * 3, 3600].max.round
      end

      # Calculate the TTL for the garbage collection lock.
      # Should be a bit longer than the heartbeat interval.
      #
      # @return [Integer] TTL in seconds
      def gc_lock_ttl
        # Set to 2x the heartbeat interval, with a minimum of 120 seconds
        [config.heartbeat_interval * 2, 120].max
      end

      # Calculate the TTL for the last GC run timestamp.
      # Should be a bit longer than the heartbeat interval to ensure
      # proper coordination across processes.
      #
      # @return [Integer] TTL in seconds
      def gc_last_run_ttl
        # Set to 1.5x the heartbeat interval
        (config.heartbeat_interval * 1.5).round
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
        max_connections_key_for(@lock_identifier)
      end

      def max_connections_key_for(process_id)
        "#{PROCESS_SET_KEY}:#{process_id}:max_connections"
      end

      def processors_key
        "#{PROCESS_SET_KEY}:#{@lock_identifier}:processors"
      end

      # Serialize a per-processor snapshot for publication.
      #
      # @param snapshot [Hash] processor name => { inflight:, max_capacity: }
      # @return [String] the serialized snapshot
      def serialize_processor_snapshot(snapshot)
        JSON.generate(
          snapshot.each_with_object({}) do |(name, counts), hash|
            hash[name.to_s] = {
              "inflight" => counts[:inflight].to_i,
              "max_capacity" => counts[:max_capacity].to_i
            }
          end
        )
      end
    end
  end
end
