# frozen_string_literal: true

require "time"
require "socket"

module Sidekiq
  module AsyncHttp
    # Stores processor statistics in Redis with automatic expiration.
    #
    # This singleton class tracks various metrics about async HTTP requests,
    # including total requests, errors, refused requests, and current inflight counts
    # across all processes. Statistics are stored in Redis with appropriate TTLs.
    class Stats
      # Redis key prefixes
      TOTALS_KEY = "sidekiq:async_http:totals"
      INFLIGHT_PREFIX = "sidekiq:async_http:inflight"
      MAX_CONNECTIONS_PREFIX = "sidekiq:async_http:max_connections"
      PROCESS_SET_KEY = "sidekiq:async_http:processes"

      # TTLs
      TOTALS_TTL = 30 * 24 * 60 * 60 # 30 days in seconds
      INFLIGHT_TTL = 30

      def initialize(config = nil)
        @hostname = ::Socket.gethostname.force_encoding("UTF-8").freeze
        @pid = ::Process.pid
        @config = config
      end

      # Record a completed request
      #
      # @param duration [Float] request duration in seconds
      # @return [void]
      def record_request(duration)
        Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.hincrby(TOTALS_KEY, "requests", 1)
            transaction.hincrbyfloat(TOTALS_KEY, "duration", duration.to_f)
            transaction.expire(TOTALS_KEY, TOTALS_TTL)
          end
        end
      rescue => e
        handle_error(e)
      end

      # Record a request error
      #
      # @param error_type [String] the type of error that occurred
      # @return [void]
      def record_error(error_type)
        Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.hincrby(TOTALS_KEY, "errors", 1)
            transaction.expire(TOTALS_KEY, TOTALS_TTL)
          end
        end
      rescue => e
        handle_error(e)
      end

      # Record a refused request (max capacity reached)
      #
      # @return [void]
      def record_refused
        Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.hincrby(TOTALS_KEY, "refused", 1)
            transaction.expire(TOTALS_KEY, TOTALS_TTL)
          end
        end
      rescue => e
        handle_error(e)
      end

      # Update the inflight request count and max connections for this process
      #
      # @param count [Integer] current number of inflight requests
      # @param max_connections [Integer] maximum connections for this process
      # @return [void]
      def update_inflight(count, max_connections)
        inflight_key = "#{INFLIGHT_PREFIX}:#{@hostname}:#{@pid}"
        max_connections_key = "#{MAX_CONNECTIONS_PREFIX}:#{@hostname}:#{@pid}"
        process_id = "#{@hostname}:#{@pid}"

        Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.set(inflight_key, count, ex: INFLIGHT_TTL)
            transaction.set(max_connections_key, max_connections, ex: INFLIGHT_TTL)
            transaction.sadd(PROCESS_SET_KEY, process_id)
          end
        end
      rescue => e
        handle_error(e)
      end

      # Get running totals
      #
      # @return [Hash] hash with requests, duration, errors, refused
      def get_totals
        Sidekiq.redis do |redis|
          stats = redis.hgetall(TOTALS_KEY)
          {
            "requests" => (stats["requests"] || 0).to_i,
            "duration" => (stats["duration"] || 0).to_f.round(6),
            "errors" => (stats["errors"] || 0).to_i,
            "refused" => (stats["refused"] || 0).to_i
          }
        end
      end

      # Get all inflight counts across all processes and the number of max connections.
      #
      # @return [Hash] hash of "hostname:pid" => { count: Integer, max: Integer }
      def get_all_inflight
        Sidekiq.redis do |redis|
          process_ids = redis.smembers(PROCESS_SET_KEY)
          return {} if process_ids.empty?

          inflight_keys = process_ids.map { |pid| "#{INFLIGHT_PREFIX}:#{pid}" }
          max_keys = process_ids.map { |pid| "#{MAX_CONNECTIONS_PREFIX}:#{pid}" }

          inflight_values = redis.mget(*inflight_keys)
          max_values = redis.mget(*max_keys)

          result = {}
          stale_process_ids = []

          process_ids.zip(inflight_values, max_values).each do |process_id, count, max_conn|
            if count.nil? || max_conn.nil?
              # Mark for removal if either key doesn't exist
              stale_process_ids << process_id
            else
              result[process_id] = {count: count.to_i, max: max_conn.to_i}
            end
          end

          # Remove stale process IDs from the set
          redis.srem(PROCESS_SET_KEY, stale_process_ids) unless stale_process_ids.empty?

          result
        end
      end

      # Get the total max connections across all processes
      #
      # @return [Integer] sum of max connections from all active processes
      def get_total_max_connections
        Sidekiq.redis do |redis|
          process_ids = redis.smembers(PROCESS_SET_KEY)
          total = 0
          stale_process_ids = []

          process_ids.each do |process_id|
            max_connections_key = "#{MAX_CONNECTIONS_PREFIX}:#{process_id}"
            max_connections = redis.get(max_connections_key)

            if max_connections.nil?
              # Mark for removal if the key doesn't exist
              stale_process_ids << process_id
            else
              total += max_connections.to_i
            end
          end

          # Remove stale process IDs from the set
          redis.srem(PROCESS_SET_KEY, stale_process_ids) unless stale_process_ids.empty?

          total
        end
      end

      # Remove process-specific keys (called during processor shutdown)
      #
      # @return [void]
      def cleanup_process_keys
        inflight_key = "#{INFLIGHT_PREFIX}:#{@hostname}:#{@pid}"
        max_connections_key = "#{MAX_CONNECTIONS_PREFIX}:#{@hostname}:#{@pid}"
        process_id = "#{@hostname}:#{@pid}"

        Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.del(inflight_key)
            transaction.del(max_connections_key)
            transaction.srem(PROCESS_SET_KEY, process_id)
          end
        end
      end

      # Get total inflight count across all processes
      #
      # @return [Integer] total number of inflight requests
      def get_total_inflight
        get_all_inflight.values.sum { |h| h[:count] }
      end

      # Reset all stats (useful for testing)
      #
      # @return [void]
      def reset!
        Sidekiq.redis do |redis|
          # Delete totals
          redis.del(TOTALS_KEY)

          # Delete all inflight keys
          inflight_keys = redis.keys("#{INFLIGHT_PREFIX}:*")
          redis.del(*inflight_keys) unless inflight_keys.empty?

          # Delete all max_connections keys
          max_connections_keys = redis.keys("#{MAX_CONNECTIONS_PREFIX}:*")
          redis.del(*max_connections_keys) unless max_connections_keys.empty?

          # Clear the process set
          redis.del(PROCESS_SET_KEY)
        end
      end

      private

      def handle_error(error)
        @config&.logger&.error("[Sidekiq::AsyncHttp] Stats error: #{error.inspect}")
        raise error if AsyncHttp.testing?
      end
    end
  end
end
