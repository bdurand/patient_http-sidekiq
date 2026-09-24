# frozen_string_literal: true

require "digest"
require "uri"

module PatientHttp
  module Sidekiq
    # Tracks in-flight requests in Redis for crash recovery.
    #
    # The registry keeps a sorted set of request IDs, scored by heartbeat
    # time, and a Hash of the Sidekiq job for each request. If a process
    # crashes, another process finds the orphaned requests and re-enqueues
    # their jobs. A distributed lock lets only one process at a time look for
    # orphaned requests.
    #
    # Each entry has a registry ID in the format
    # <tt>hostname:pid:hex/request-uuid</tt>:
    #
    # - +hostname+: The host name, with colons and slashes replaced by dashes.
    # - +pid+: The process ID.
    # - +hex+: 16 random hex characters that make the ID unique.
    # - +request-uuid+: The request ID.
    class TaskMonitor
      # Redis key for the sorted set of in-flight request IDs, scored by
      # heartbeat time.
      INFLIGHT_INDEX_KEY = "sidekiq:patient_http:inflight_index"

      # Redis key for the Hash of Sidekiq jobs, keyed by registry ID.
      INFLIGHT_JOBS_KEY = "sidekiq:patient_http:inflight_jobs"

      # Redis key for the Hash of request details shown in the Web UI, keyed by
      # registry ID.
      INFLIGHT_DETAILS_KEY = "sidekiq:patient_http:inflight_details"

      # Redis key for the sorted set of request IDs with details, scored by
      # registration time.
      INFLIGHT_DETAILS_INDEX_KEY = "sidekiq:patient_http:inflight_details_index"

      # Redis key for the set of registered process IDs. Also the prefix for
      # the keys that each process publishes.
      PROCESS_SET_KEY = "sidekiq:patient_http:processes"

      # Redis key for the garbage collection lock.
      GC_LOCK_KEY = "sidekiq:patient_http:gc_lock"

      # Redis key for the time of the last garbage collection run.
      GC_LAST_RUN_KEY = "sidekiq:patient_http:gc_last_run"

      # Lua script that removes a batch of orphaned requests. For each ID, the
      # script checks that the request is still orphaned (its heartbeat is
      # older than the threshold) and removes it in the same atomic step, so a
      # heartbeat can't update the request between the check and the removal.
      # The script skips IDs that are no longer orphaned.
      #
      # KEYS[1] = index key (sorted set)
      # KEYS[2] = jobs key (hash)
      # KEYS[3] = details key (hash)
      # KEYS[4] = details index key (sorted set)
      # ARGV[1] = threshold_ms
      # ARGV[2..] = request_ids
      #
      # The script returns every removed ID, even when the jobs Hash no longer
      # has its payload, so that the caller can use the payload it read before
      # the script ran instead of losing the request.
      #
      # Returns: A flat Array of [request_id, job_payload, request_id,
      #   job_payload, ...]. The job_payload is nil if the Hash entry was
      #   already gone.
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

      # The SHA1 digest of REMOVE_IF_ORPHANED_SCRIPT.
      REMOVE_IF_ORPHANED_SHA = Digest::SHA1.hexdigest(REMOVE_IF_ORPHANED_SCRIPT).freeze

      # Lua script that releases the garbage collection lock only if this
      # process still holds it. The check and the delete happen in one round
      # trip.
      #
      # KEYS[1] = lock key
      # ARGV[1] = lock identifier
      #
      # Returns: 1 if the lock was released, otherwise 0.
      RELEASE_LOCK_SCRIPT = <<~LUA
        if redis.call('GET', KEYS[1]) == ARGV[1] then
          return redis.call('DEL', KEYS[1])
        else
          return 0
        end
      LUA

      # The SHA1 digest of RELEASE_LOCK_SCRIPT.
      RELEASE_LOCK_SHA = Digest::SHA1.hexdigest(RELEASE_LOCK_SCRIPT).freeze

      # The number of orphaned request IDs that each Lua call processes.
      ORPHAN_BATCH_SIZE = 100

      # The maximum length of a URL recorded for the Web UI, so that one long
      # URL can't use a large amount of memory.
      MAX_DISPLAY_URL_LENGTH = 500

      # @return [Configuration] The gem configuration.
      attr_reader :config

      class << self
        # Returns the number of in-flight requests across all processes.
        #
        # @return [Integer] The number of in-flight requests.
        def inflight_count
          ::Sidekiq.redis do |redis|
            redis.zcard(INFLIGHT_INDEX_KEY)
          end
        end

        # Returns the in-flight count and capacity of each running process.
        # Also removes processes that stopped sending heartbeats from the
        # process set.
        #
        # The in-flight count for each process comes from the shared registry,
        # so it can include requests left behind by a process that died. The
        # per-processor counts come from snapshots that each process publishes
        # with its heartbeat. They cover only running processes and can be up
        # to one monitor pass old.
        #
        # @return [Hash{String => Hash}] The counts, keyed by +hostname:pid+.
        #   Each value has +:inflight+, +:max_capacity+, and +:processors+
        #   keys. The +:processors+ value has the +:inflight+ and
        #   +:max_capacity+ counts, keyed by processor name.
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

        # Returns the in-flight count and capacity of each named processor
        # across all running processes.
        #
        # @param processes [Hash, nil] The result of
        #   {inflight_counts_by_process}. If +nil+, reads the counts from Redis.
        # @return [Hash{String => Hash}] The +:inflight+ and +:max_capacity+
        #   counts, keyed by processor name.
        def inflight_counts_by_processor(processes = nil)
          processes ||= inflight_counts_by_process

          result = {}
          processes.each_value do |data|
            merge_processor_counts(result, data[:processors])
          end
          result.sort.to_h
        end

        # Returns the details of the requests that have been in flight the
        # longest.
        #
        # The result includes only requests registered while the
        # +inflight_details+ option was enabled. A request stays listed while
        # its crash-recovery record exists. As a result, a request left behind
        # by a process that died stays listed until the orphan collector
        # re-enqueues it.
        #
        # @param limit [Integer] The maximum number of requests to return.
        # @return [Array<Hash>] The requests, oldest first. Each Hash has
        #   +:request_id+, +:process_id+, +:url+, +:http_method+, +:processor+,
        #   and +:age+ keys. The +:age+ value is in seconds.
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

        # Removes the user name, password, query string, and fragment from a
        # URL, and keeps the scheme, host, and path. Used when the
        # +inflight_url_sanitizer+ option isn't set.
        #
        # @param url [String] The request URL.
        # @return [String] The URL to display.
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

        # Returns the total capacity of all running processes.
        #
        # @return [Integer] The sum of +max_connections+ across all running
        #   processes.
        def total_max_connections
          inflight_counts_by_process.values.sum { |data| data[:max_capacity] }
        end

        # Returns the IDs of all registered processes.
        #
        # @return [Array<String>] The process IDs.
        def registered_process_ids
          ::Sidekiq.redis do |redis|
            redis.smembers(PROCESS_SET_KEY)
          end
        end

        # Deletes all registry data. Allowed only in tests.
        #
        # @return [void]
        # @raise [RuntimeError] If called outside tests.
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

        # Returns the Redis key for a process's capacity.
        #
        # @param process_id [String] The process ID.
        # @return [String] The Redis key.
        def max_connections_key_for(process_id)
          "#{PROCESS_SET_KEY}:#{process_id}:max_connections"
        end

        # Returns the Redis key for a process's per-processor snapshot.
        #
        # @param process_id [String] The process ID.
        # @return [String] The Redis key.
        def processors_key_for(process_id)
          "#{PROCESS_SET_KEY}:#{process_id}:processors"
        end

        # Removes the user information between the scheme and the host of a
        # URL.
        #
        # @param url [String] The URL.
        # @return [String] The URL without credentials.
        def strip_credentials(url)
          url.sub(%r{\A([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]*@}, '\\1')
        end

        # Parses a stored details record.
        #
        # @param record [String, nil] The serialized record.
        # @return [Hash, nil] The parsed record, or +nil+ if the record can't be
        #   parsed.
        def parse_details(record)
          return nil if record.nil?

          details = JSON.parse(record)
          details.is_a?(Hash) ? details : nil
        rescue JSON::ParserError
          nil
        end

        # Adds the counts from a process's published snapshot to per-processor
        # counts.
        #
        # A process that runs a different version of the gem might publish a
        # snapshot that can't be read. That snapshot is skipped so that the
        # rest of the report still works.
        #
        # @param counts [Hash] The per-processor counts to add to.
        # @param snapshot [String, nil] The serialized snapshot.
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

        # Adds per-processor counts to a running total.
        #
        # @param counts [Hash] The per-processor counts to add to.
        # @param additions [Hash, nil] The per-processor counts to add.
        # @return [void]
        def merge_processor_counts(counts, additions)
          additions&.each do |name, values|
            totals = (counts[name] ||= {inflight: 0, max_capacity: 0})
            totals[:inflight] += values[:inflight].to_i
            totals[:max_capacity] += values[:max_capacity].to_i
          end
        end
      end

      # Creates a registry for the current process.
      #
      # @param config [Configuration] The gem configuration.
      # @param max_connections [#call, nil] A callable that returns the
      #   process's total +max_connections+. If +nil+, uses the configuration
      #   value. Ignored when +processors+ is set, because the snapshot has the
      #   same information for each processor.
      # @param processors [#call, nil] A callable that returns a snapshot of
      #   the process's processors: the +:inflight+ and +:max_capacity+ counts,
      #   keyed by processor name. The snapshot is published with each
      #   heartbeat so that the Web UI can report capacity for each processor.
      def initialize(config, max_connections: nil, processors: nil)
        @config = config
        @max_connections_source = max_connections || -> { config.max_connections }
        @processors_source = processors
        hostname = ::Socket.gethostname.force_encoding("UTF-8").tr(":/", "-")
        pid = ::Process.pid
        @lock_identifier = "#{hostname}:#{pid}:#{SecureRandom.hex(8)}".freeze
      end

      # Adds a request to the registry.
      #
      # @param task [PatientHttp::RequestTask] The request task.
      # @param processor_name [Symbol, String, nil] The name of the processor
      #   that runs the request. Recorded with the request details.
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

      # Removes a request from the registry.
      #
      # @param task [PatientHttp::RequestTask] The request task.
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

      # Removes this process from the process set.
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

      # Updates the heartbeat times of requests in one pipelined call.
      #
      # @param task_ids [Array<String>] The request IDs.
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

      # Returns whether a request is in the registry.
      #
      # @param task [PatientHttp::RequestTask] The request task.
      # @return [Boolean] +true+ if the request is registered.
      # @api private
      def registered?(task)
        PatientHttp::Sidekiq.redis do |redis|
          !redis.zscore(INFLIGHT_INDEX_KEY, full_task_id(task.id)).nil?
        end
      end

      # Returns the heartbeat time of a request.
      #
      # @param task [PatientHttp::RequestTask] The request task.
      # @return [Integer, nil] The time in milliseconds since the epoch, or
      #   +nil+ if the request isn't registered.
      # @api private
      def heartbeat_timestamp_for(task)
        score = PatientHttp::Sidekiq.redis do |redis|
          redis.zscore(INFLIGHT_INDEX_KEY, full_task_id(task.id))
        end
        score&.to_i
      end

      # Returns the registry IDs of all requests that this process registered.
      #
      # @return [Array<String>] The registry IDs.
      # @api private
      def registered_task_ids
        PatientHttp::Sidekiq.redis do |redis|
          redis.zrange(INFLIGHT_INDEX_KEY, 0, -1)
        end.select { |id| id.start_with?("#{@lock_identifier}/") }
      end

      # Returns the registry ID for a request. The registry ID includes this
      # process's ID.
      #
      # @param task_id [String] The request ID.
      # @return [String] The registry ID.
      def full_task_id(task_id)
        "#{@lock_identifier}/#{task_id}"
      end

      # Registers this process and publishes its capacity.
      #
      # The Web UI reads the capacity. The capacity key also shows that the
      # process is alive: every heartbeat refreshes the key, and its TTL is
      # shorter than the TTL of the process set. If a process in the set has no
      # capacity key, the process is gone.
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

      # Tries to get the distributed garbage collection lock.
      #
      # @return [Boolean] +true+ if this process got the lock.
      def acquire_gc_lock
        PatientHttp::Sidekiq.redis do |redis|
          # Use SET with NX and EX options directly
          # Returns "OK" if successful, nil if key already exists
          !!redis.set(GC_LOCK_KEY, @lock_identifier, nx: true, ex: gc_lock_ttl)
        end
      end

      # Releases the garbage collection lock if this process holds it. A Lua
      # script checks and deletes the lock atomically in one round trip.
      #
      # @return [Boolean] +true+ if the lock was released.
      def release_gc_lock
        result = PatientHttp::Sidekiq.redis do |redis|
          run_script(redis, RELEASE_LOCK_SCRIPT, RELEASE_LOCK_SHA, [GC_LOCK_KEY], [@lock_identifier])
        end
        result == 1
      end

      # Returns whether garbage collection is due. Garbage collection is due if
      # no run is recorded or if one heartbeat interval has passed since the
      # last run.
      #
      # @return [Boolean] +true+ if garbage collection is due.
      def gc_needed?
        last_run = PatientHttp::Sidekiq.redis do |redis|
          redis.get(GC_LAST_RUN_KEY)
        end

        return true if last_run.nil?

        last_run_time = Time.at(last_run.to_f / 1000.0)
        Time.now - last_run_time >= config.heartbeat_interval
      end

      # Records the time of the last garbage collection run in Redis so that
      # processes can coordinate their runs. The record expires a little after
      # one heartbeat interval.
      #
      # @return [void]
      def record_gc_run
        PatientHttp::Sidekiq.redis do |redis|
          redis.set(GC_LAST_RUN_KEY, (Time.now.to_f * 1000).floor, ex: gc_last_run_ttl)
        end
      end

      # Finds orphaned requests and re-enqueues their jobs.
      #
      # @param orphan_threshold_seconds [Numeric] The number of seconds without
      #   a heartbeat after which a request is orphaned.
      # @param logger [Logger, nil] The logger.
      # @return [Integer] The number of requests re-enqueued.
      def cleanup_orphaned_requests(orphan_threshold_seconds, logger)
        threshold_timestamp_ms = calculate_threshold_timestamp(orphan_threshold_seconds)
        orphaned_requests = fetch_orphaned_requests(threshold_timestamp_ms)

        return 0 if orphaned_requests.empty?

        reenqueue_orphaned_jobs(orphaned_requests, threshold_timestamp_ms, logger)
      end

      private

      # Returns the heartbeat time before which a request is orphaned.
      #
      # @param orphan_threshold_seconds [Numeric] The threshold in seconds.
      # @return [Integer] The time in milliseconds since the epoch.
      def calculate_threshold_timestamp(orphan_threshold_seconds)
        ((Time.now.to_f - orphan_threshold_seconds) * 1000).round
      end

      # Returns the IDs and job payloads of orphaned requests. Skips requests
      # from processes that are still alive.
      #
      # @param threshold_timestamp_ms [Integer] The heartbeat time, in
      #   milliseconds since the epoch, before which a request is orphaned.
      # @return [Array<Array(String, String)>] The [request_id, job_payload]
      #   pairs.
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

      # Returns the process IDs that belong to live processes, and removes dead
      # processes from the process set.
      #
      # Membership in the process set doesn't prove that a process is alive,
      # because a crashed process never removes itself. A process is alive only
      # if its capacity key still exists. Every heartbeat refreshes the key,
      # which has a short TTL. Removing dead processes from the set lets their
      # in-flight requests be recovered.
      #
      # @param process_ids [Array<String>] The process IDs to check.
      # @return [Array<String>] The IDs of live processes.
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

      # Re-enqueues the jobs of orphaned requests.
      #
      # The IDs are processed in batches. One Lua call checks and removes each
      # batch atomically. Then each removed job is pushed to Sidekiq with its
      # original class, queue, and job ID.
      #
      # @param orphaned_requests [Array<Array(String, String)>] The
      #   [request_id, job_payload] pairs.
      # @param threshold_timestamp_ms [Integer] The heartbeat time, in
      #   milliseconds since the epoch, before which a request is orphaned.
      # @param logger [Logger, nil] The logger.
      # @return [Integer] The number of jobs re-enqueued.
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

      # Removes the requests in a batch that are still orphaned. A Lua script
      # checks and removes each request atomically, so a heartbeat can't
      # update a request between the check and the removal.
      #
      # @param request_ids [Array<String>] The request IDs to check.
      # @param threshold_timestamp_ms [Integer] The heartbeat time, in
      #   milliseconds since the epoch, before which a request is orphaned.
      # @return [Array<String, nil>] A flat Array of request ID and job payload
      #   pairs.
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

      # Runs a Lua script by its SHA1 digest. If the server doesn't have the
      # script cached, runs the full script with EVAL, which also caches it.
      #
      # @param redis [Object] The Redis connection.
      # @param script [String] The Lua source.
      # @param sha [String] The SHA1 digest of the source.
      # @param keys [Array<String>] The script KEYS.
      # @param argv [Array<String>] The script ARGV.
      # @return [Object] The return value of the script.
      def run_script(redis, script, sha, keys, argv)
        redis.call("EVALSHA", sha, keys.size, *keys, *argv)
      rescue RedisClient::CommandError => e
        raise unless e.message.include?("NOSCRIPT")

        redis.call("EVAL", script, keys.size, *keys, *argv)
      end

      # Returns the serialized details to record for a request. A failure here
      # must not stop the request from being registered, so the failure is
      # logged and the details are skipped.
      #
      # @param task [PatientHttp::RequestTask] The request task.
      # @param processor_name [Symbol, String, nil] The name of the processor
      #   that runs the request.
      # @return [String, nil] The serialized details, or +nil+ if the
      #   +inflight_details+ option is off or the details can't be built.
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

      # Returns the URL to record for a request, sanitized and truncated to
      # MAX_DISPLAY_URL_LENGTH.
      #
      # @param url [String] The request URL.
      # @return [String] The URL to display.
      def display_url(url)
        sanitizer = config.inflight_url_sanitizer
        sanitized = sanitizer ? sanitizer.call(url) : self.class.sanitize_url(url)
        sanitized.to_s[0, MAX_DISPLAY_URL_LENGTH]
      end

      # Returns the TTL for the in-flight registry keys. The TTL is much longer
      # than the orphan threshold.
      #
      # @return [Integer] The TTL in seconds.
      def inflight_ttl
        # Set to 3x the orphan threshold, with a minimum of 1 hour
        [config.orphan_threshold * 3, 3600].max.round
      end

      # Returns the TTL for the garbage collection lock. The TTL is longer than
      # the heartbeat interval.
      #
      # @return [Integer] The TTL in seconds.
      def gc_lock_ttl
        # Set to 2x the heartbeat interval, with a minimum of 120 seconds
        [config.heartbeat_interval * 2, 120].max
      end

      # Returns the TTL for the last garbage collection run record. The TTL is
      # a little longer than the heartbeat interval so that processes can
      # coordinate their runs.
      #
      # @return [Integer] The TTL in seconds.
      def gc_last_run_ttl
        # Set to 1.5x the heartbeat interval
        (config.heartbeat_interval * 1.5).round
      end

      # Returns the TTL for a process's capacity key. The TTL is longer than
      # the heartbeat interval so that the key lasts from one heartbeat to the
      # next.
      #
      # @return [Integer] The TTL in seconds.
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

      # Serializes a per-processor snapshot for publication.
      #
      # @param snapshot [Hash{Symbol => Hash}] The +:inflight+ and
      #   +:max_capacity+ counts, keyed by processor name.
      # @return [String] The serialized snapshot.
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
