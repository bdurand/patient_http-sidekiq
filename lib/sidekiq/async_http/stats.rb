# frozen_string_literal: true

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

      # TTLs
      TOTALS_TTL = 30 * 24 * 60 * 60 # 30 days in seconds

      def initialize(config = nil)
        @hostname = ::Socket.gethostname.force_encoding("UTF-8").freeze
        @pid = ::Process.pid
        @config = config
      end

      # Record a completed request
      #
      # @param duration [Float] request duration in seconds
      # @return [void]
      def record_request(status, duration)
        Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.hincrby(TOTALS_KEY, "requests", 1)
            transaction.hincrbyfloat(TOTALS_KEY, "duration", duration.to_f)
            transaction.hincrby(TOTALS_KEY, "http_status:#{status}", 1) if status && status >= 100 && status < 600
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
            transaction.hincrby(TOTALS_KEY, "errors:#{error_type}", 1)
            transaction.expire(TOTALS_KEY, TOTALS_TTL)
          end
        end
      rescue => e
        handle_error(e)
      end

      # Record a that a request was refused because the max capacity of the Processor was reached.
      #
      # @return [void]
      def record_capacity_exceeded
        Sidekiq.redis do |redis|
          redis.multi do |transaction|
            transaction.hincrby(TOTALS_KEY, "max_capacity_exceeded", 1)
            transaction.expire(TOTALS_KEY, TOTALS_TTL)
          end
        end
      rescue => e
        handle_error(e)
      end

      # Get running totals
      #
      # @return [Hash] hash with requests, duration, errors, max_capacity_exceeded, http_status_counts
      def get_totals
        Sidekiq.redis do |redis|
          stats = redis.hgetall(TOTALS_KEY)

          # Extract HTTP status counts and error type counts
          http_status_counts = {}
          error_type_counts = {}
          stats.each do |key, value|
            if key.start_with?("http_status:")
              status = key.sub("http_status:", "").to_i
              http_status_counts[status] = value.to_i
            elsif key.start_with?("errors:") && key != "errors"
              error_type = key.sub("errors:", "")
              error_type_counts[error_type] = value.to_i
            end
          end

          {
            "requests" => (stats["requests"] || 0).to_i,
            "duration" => (stats["duration"] || 0).to_f.round(6),
            "errors" => (stats["errors"] || 0).to_i,
            "max_capacity_exceeded" => (stats["max_capacity_exceeded"] || 0).to_i,
            "http_status_counts" => http_status_counts.sort.to_h,
            "error_type_counts" => error_type_counts.sort.to_h
          }
        end
      end

      # Reset all stats (useful for testing)
      #
      # @return [void]
      def reset!
        Sidekiq.redis do |redis|
          redis.del(TOTALS_KEY)
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
