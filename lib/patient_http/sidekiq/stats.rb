# frozen_string_literal: true

require "digest"

module PatientHttp
  module Sidekiq
    # Tracks processor stats with local aggregation.
    #
    # Each process adds up counters in memory and flushes them to a Redis Hash
    # at the interval set by the `stats_flush_interval` option. As a result,
    # recording a request costs a Hash increment instead of a Redis round
    # trip, and processes don't write the shared totals key on every request.
    # The counters are increments, so concurrent flushes from many processes
    # are safe. If a flush fails, the counters are kept for the next flush. A
    # process that crashes loses at most one interval of counters.
    class Stats
      include PatientHttp::TimeHelper

      # The Redis key for the totals Hash.
      TOTALS_KEY = "sidekiq:patient_http:totals"

      # The number of seconds that the totals Hash lives after its last flush.
      TOTALS_TTL = 30 * 24 * 60 * 60 # 30 days in seconds

      # Metrics reported for every processor. A processor that has recorded
      # only some of them reports the others as zero.
      PROCESSOR_METRICS = {
        "requests" => 0,
        "duration" => 0.0,
        "errors" => 0,
        "max_capacity_exceeded" => 0,
        "max_inflight" => 0
      }.freeze

      # Lua script that raises fields to new high-water marks. A field is
      # written only when the new value is higher, so concurrent writes from
      # many processes keep the highest value.
      #
      # KEYS[1] = totals key
      # ARGV = alternating field and value
      RECORD_MAXIMA_SCRIPT = <<~LUA
        for i = 1, #ARGV, 2 do
          local field = ARGV[i]
          local value = tonumber(ARGV[i + 1])
          local current = redis.call('HGET', KEYS[1], field)
          if not current or value > tonumber(current) then
            redis.call('HSET', KEYS[1], field, value)
          end
        end

        return 1
      LUA

      # The SHA1 digest of RECORD_MAXIMA_SCRIPT.
      RECORD_MAXIMA_SHA = Digest::SHA1.hexdigest(RECORD_MAXIMA_SCRIPT).freeze

      # @return [Configuration, nil] The gem configuration, or `nil` for an
      #   aggregator that only reads and clears the totals.
      attr_reader :config

      # Creates a stats aggregator.
      #
      # @param config [Configuration, nil] The gem configuration. The Web UI
      #   passes `nil` because it only reads and clears the totals.
      def initialize(config = nil)
        @hostname = ::Socket.gethostname.force_encoding("UTF-8").freeze
        @pid = ::Process.pid
        @config = config
        @mutex = Mutex.new
        @pending = Hash.new(0)
        @maxima = Hash.new(0)
        @maxima_changed = false
        @last_flush = monotonic_time
      end

      # Records a finished request.
      #
      # @param status [Integer, nil] The HTTP status code.
      # @param duration [Float] The request duration in seconds.
      # @param processor_name [String, Symbol, nil] The name of the processor
      #   that ran the request. If set and more than one processor is
      #   configured, per-processor counters are recorded as well.
      # @return [void]
      def record_request(status, duration, processor_name: nil)
        processor = processor_field_prefix(processor_name)
        record do |pending|
          pending["requests"] += 1
          pending["duration"] += duration.to_f
          pending["http_status:#{status}"] += 1 if status && status >= 100 && status < 600
          if processor
            pending["#{processor}requests"] += 1
            pending["#{processor}duration"] += duration.to_f
          end
        end
      end

      # Records a request error.
      #
      # @param error_type [String, Symbol] The error type.
      # @param processor_name [String, Symbol, nil] The name of the processor
      #   that ran the request. If set and more than one processor is
      #   configured, per-processor counters are recorded as well.
      # @return [void]
      def record_error(error_type, processor_name: nil)
        processor = processor_field_prefix(processor_name)
        record do |pending|
          pending["errors"] += 1
          pending["errors:#{error_type}"] += 1
          pending["#{processor}errors"] += 1 if processor
        end
      end

      # Records the number of requests that a processor has in flight, and
      # keeps the highest value. The count rises only when a processor accepts
      # a request, so recording it at that moment captures every high-water
      # mark.
      #
      # @param count [Integer] The number of requests in flight.
      # @param processor_name [String, Symbol, nil] The processor name. Nothing
      #   is recorded if this is `nil` or only one processor is configured.
      # @return [void]
      def record_inflight_peak(count, processor_name:)
        processor = processor_field_prefix(processor_name)
        return unless processor

        field = "#{processor}max_inflight"
        @mutex.synchronize do
          next unless count > @maxima[field]

          @maxima[field] = count
          @maxima_changed = true
        end
      end

      # Records that a processor refused a request because it was at capacity.
      #
      # @param processor_name [String, Symbol, nil] The name of the processor
      #   that refused the request. If set and more than one processor is
      #   configured, per-processor counters are recorded as well.
      # @return [void]
      def record_capacity_exceeded(processor_name: nil)
        processor = processor_field_prefix(processor_name)
        record do |pending|
          pending["max_capacity_exceeded"] += 1
          pending["#{processor}max_capacity_exceeded"] += 1 if processor
        end
      end

      # Writes pending counters to Redis in one pipelined call. If the write
      # fails, keeps the counters for the next flush.
      #
      # @return [void]
      def flush
        pending = nil
        maxima = nil
        @mutex.synchronize do
          @last_flush = monotonic_time
          pending, @pending = @pending, Hash.new(0)
          # The high-water marks are not consumed: they are the highest values
          # this process has seen, and they are sent on every flush so that
          # they are restored after the totals are cleared.
          maxima = @maxima.dup
          @maxima_changed = false
        end
        # A processor that is saturated records new marks without completing
        # anything, so a new mark is a reason to flush on its own.
        return if pending.empty? && maxima.empty?

        begin
          # The pipeline is a batch of increments, so it must not be replayed
          # after a connection failure: the server may already have applied it
          # and a replay would double count. A failure merges the deltas back
          # instead, which at worst loses them if the write did land.
          PatientHttp::Sidekiq.redis(retry_on_connection_error: false) do |redis|
            redis.pipelined do |pipeline|
              pending.each do |field, delta|
                if float_field?(field)
                  pipeline.hincrbyfloat(TOTALS_KEY, field, delta)
                else
                  pipeline.hincrby(TOTALS_KEY, field, delta)
                end
              end
              pipeline.expire(TOTALS_KEY, TOTALS_TTL)
            end
          end
          flush_maxima(maxima)
        rescue => e
          # Put the deltas back so nothing is lost; they are retried on the
          # next flush.
          @mutex.synchronize do
            pending.each { |field, delta| @pending[field] += delta }
            @maxima_changed = true if maxima.any?
          end
          handle_error(e)
        end
      end

      # Flushes if the flush interval has passed since the last flush. The
      # monitor thread calls this method on each pass.
      #
      # @return [void]
      def flush_if_due
        due = @mutex.synchronize do
          (@pending.any? || @maxima_changed) && (monotonic_time - @last_flush >= flush_interval)
        end
        flush if due
      end

      # Returns the totals from Redis. Flushes this process's pending counters
      # first.
      #
      # @return [Hash] The totals, with `requests`, `duration`, `errors`,
      #   `max_capacity_exceeded`, `http_status_counts`, and
      #   `error_type_counts` keys. When per-processor counters exist, a
      #   `processors` key holds them, keyed by processor name.
      def get_totals
        # Flush first so this process's own recorded events are visible.
        # Other processes' unflushed deltas are stale by at most their flush
        # interval.
        flush

        PatientHttp::Sidekiq.redis do |redis|
          stats = redis.hgetall(TOTALS_KEY)

          # Extract HTTP status counts, error type counts, and per-processor counts
          http_status_counts = {}
          error_type_counts = {}
          processor_counts = {}
          stats.each do |key, value|
            if key.start_with?("http_status:")
              status = key.sub("http_status:", "").to_i
              http_status_counts[status] = value.to_i
            elsif key.start_with?("errors:") && key != "errors"
              error_type = key.sub("errors:", "")
              error_type_counts[error_type] = value.to_i
            elsif key.start_with?("processor:")
              _, name, metric = key.split(":", 3)
              next unless name && metric

              counts = (processor_counts[name] ||= PROCESSOR_METRICS.dup)
              counts[metric] = (metric == "duration") ? value.to_f.round(6) : value.to_i
            end
          end

          totals = {
            "requests" => (stats["requests"] || 0).to_i,
            "duration" => (stats["duration"] || 0).to_f.round(6),
            "errors" => (stats["errors"] || 0).to_i,
            "max_capacity_exceeded" => (stats["max_capacity_exceeded"] || 0).to_i,
            "http_status_counts" => http_status_counts.sort.to_h,
            "error_type_counts" => error_type_counts.sort.to_h
          }
          totals["processors"] = processor_counts.sort.to_h if processor_counts.any?
          totals
        end
      end

      # Clears all stats in memory and in Redis. The Web UI calls this method
      # when a user clears the stats.
      #
      # @return [void]
      def reset!
        @mutex.synchronize do
          @pending = Hash.new(0)
          @maxima = Hash.new(0)
          @maxima_changed = false
          @last_flush = monotonic_time
        end
        PatientHttp::Sidekiq.redis do |redis|
          redis.del(TOTALS_KEY)
        end
      end

      private

      # Applies counter increments under the mutex. If the flush interval is
      # `0`, flushes right away so that every event is written to Redis
      # immediately.
      #
      # @yield [pending] The block that applies the increments.
      # @yieldparam pending [Hash{String => Numeric}] The pending counters.
      # @return [void]
      def record
        @mutex.synchronize do
          yield @pending
        end
        flush if flush_interval.zero?
      end

      # Raises the stored high-water marks to this process's values. This call
      # is separate from the increments because a maximum is a read followed by
      # a conditional write, which must run on the server as a script.
      #
      # @param maxima [Hash{String => Integer}] The high-water marks, keyed by
      #   field.
      # @return [void]
      def flush_maxima(maxima)
        return if maxima.empty?

        argv = maxima.flat_map { |field, value| [field, value.to_s] }
        PatientHttp::Sidekiq.redis(retry_on_connection_error: false) do |redis|
          redis.call("EVALSHA", RECORD_MAXIMA_SHA, 1, TOTALS_KEY, *argv)
        rescue RedisClient::CommandError => e
          raise unless e.message.include?("NOSCRIPT")

          redis.call("EVAL", RECORD_MAXIMA_SCRIPT, 1, TOTALS_KEY, *argv)
        end
      end

      def flush_interval
        @config&.stats_flush_interval || 5
      end

      # Returns the field name prefix for a processor's counters. Returns `nil`
      # when only one processor profile is declared, because its counters
      # would duplicate the totals.
      #
      # Colons separate the parts of a field name, so colons in the processor
      # name are replaced with dashes.
      #
      # @param processor_name [String, Symbol, nil] The processor name.
      # @return [String, nil] The prefix, or `nil` to skip per-processor
      #   counters.
      def processor_field_prefix(processor_name)
        return nil if processor_name.nil?
        return nil if @config && !@config.multiple_processors?

        "processor:#{processor_name.to_s.tr(":", "-")}:"
      end

      def float_field?(field)
        field == "duration" || field.end_with?(":duration")
      end

      def handle_error(error)
        @config&.logger&.error("[PatientHttp::Sidekiq] Stats error: #{error.inspect}")
        raise error if PatientHttp.testing?
      end
    end
  end
end
