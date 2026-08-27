# frozen_string_literal: true

require "digest"

module PatientHttp
  module Sidekiq
    # Tracks processor statistics with local aggregation.
    #
    # Metrics are accumulated in memory and flushed to a Redis hash on an
    # interval (see +stats_flush_interval+), so recording a request costs a
    # hash increment instead of a Redis round trip and the shared totals key
    # is not a per-request hot key across the fleet. Deltas are commutative
    # increments, so concurrent flushes from many processes are safe. A flush
    # failure merges the deltas back so they are retried on the next flush;
    # a crashed process loses at most one interval of counters.
    class Stats
      include PatientHttp::TimeHelper

      # Redis key prefixes
      TOTALS_KEY = "sidekiq:patient_http:totals"

      # TTLs
      TOTALS_TTL = 30 * 24 * 60 * 60 # 30 days in seconds

      # Metrics reported for every processor, so that a processor that has only
      # recorded some of them still reports the rest as zero.
      PROCESSOR_METRICS = {
        "requests" => 0,
        "duration" => 0.0,
        "errors" => 0,
        "max_capacity_exceeded" => 0,
        "max_inflight" => 0
      }.freeze

      # Lua script that raises fields to a new high-water mark. A field is only
      # written when the new value is higher, so processes recording their own
      # marks concurrently converge on the highest one.
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
      RECORD_MAXIMA_SHA = Digest::SHA1.hexdigest(RECORD_MAXIMA_SCRIPT).freeze

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

      # Record a completed request.
      #
      # @param status [Integer, nil] HTTP response status code
      # @param duration [Float] request duration in seconds
      # @param processor_name [String, Symbol, nil] name of the processor that ran
      #   the request; when given, per-processor fields are recorded as well
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

      # Record a request error
      #
      # @param error_type [String] the type of error that occurred
      # @param processor_name [String, Symbol, nil] name of the processor that ran
      #   the request; when given, per-processor fields are recorded as well
      # @return [void]
      def record_error(error_type, processor_name: nil)
        processor = processor_field_prefix(processor_name)
        record do |pending|
          pending["errors"] += 1
          pending["errors:#{error_type}"] += 1
          pending["#{processor}errors"] += 1 if processor
        end
      end

      # Record the number of requests a processor had in flight, keeping the
      # highest value seen. The count only rises when a request is handed to a
      # processor, so recording it at that moment captures every high-water
      # mark exactly.
      #
      # @param count [Integer] the number of requests in flight
      # @param processor_name [String, Symbol, nil] name of the processor
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

      # Record a that a request was refused because the max capacity of the Processor was reached.
      #
      # @param processor_name [String, Symbol, nil] name of the processor that
      #   refused the request; when given, per-processor fields are recorded as well
      # @return [void]
      def record_capacity_exceeded(processor_name: nil)
        processor = processor_field_prefix(processor_name)
        record do |pending|
          pending["max_capacity_exceeded"] += 1
          pending["#{processor}max_capacity_exceeded"] += 1 if processor
        end
      end

      # Flush pending deltas to Redis in a single pipelined write.
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

      # Flush when the configured interval has elapsed since the last flush.
      # Called periodically by the task monitor thread.
      #
      # @return [void]
      def flush_if_due
        due = @mutex.synchronize do
          (@pending.any? || @maxima_changed) && (monotonic_time - @last_flush >= flush_interval)
        end
        flush if due
      end

      # Get running totals
      #
      # @return [Hash] hash with requests, duration, errors, max_capacity_exceeded, http_status_counts
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

      # Reset all stats (useful for testing)
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

      # Apply increments under the mutex; flush synchronously when the flush
      # interval is 0 (the compatibility mode where every event writes through
      # to Redis immediately).
      def record
        @mutex.synchronize do
          yield @pending
        end
        flush if flush_interval.zero?
      end

      # Raise the stored high-water marks to this process's values. A separate
      # call because a maximum cannot be pipelined with the increments: it is a
      # read and a conditional write, which has to happen inside the server.
      #
      # @param maxima [Hash] field to value
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

      # Field name prefix for a processor's own counters, or nil when the
      # counters would carry no information. A single processor profile
      # duplicates the overall totals, so its fields are left out to keep the
      # totals hash small.
      #
      # Colons separate the field name components, so they are removed from
      # the processor name.
      #
      # @param processor_name [String, Symbol, nil] the processor name
      # @return [String, nil] the prefix, or nil to skip per-processor fields
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
