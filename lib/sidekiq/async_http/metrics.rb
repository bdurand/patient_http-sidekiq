# frozen_string_literal: true

require "concurrent"

module Sidekiq
  module AsyncHttp
    # Thread-safe metrics collection for async HTTP requests
    class Metrics
      def initialize
        @total_requests = Concurrent::AtomicFixnum.new(0)
        @error_count = Concurrent::AtomicFixnum.new(0)
        @total_duration = Concurrent::AtomicReference.new(0.0)
        @in_flight_requests = Concurrent::Map.new
        @errors_by_type = Concurrent::Map.new
        @connections_per_host = Concurrent::Map.new
      end

      # Record the start of a request
      # @param task [RequestTask] the request task being started
      # @return [void]
      def record_request_start(request)
        @in_flight_requests[request.id] = request
      end

      # Record the completion of a request
      # @param task [RequestTask] the completed request task
      # @param duration [Float] request duration in seconds
      # @return [void]
      def record_request_complete(request, duration)
        @in_flight_requests.delete(request.id)
        @total_requests.increment

        # Atomically update total_duration
        loop do
          current = @total_duration.get
          new_value = current + duration
          break if @total_duration.compare_and_set(current, new_value)
        end
      end

      # Record an error
      # @param task [RequestTask] the failed request task
      # @param error_type [Symbol] the error type (:timeout, :connection, :ssl, :protocol, :unknown)
      # @return [void]
      def record_error(request, error_type)
        @error_count.increment

        # Get or create atomic counter for this error type and increment it
        counter = @errors_by_type.compute_if_absent(error_type) do
          Concurrent::AtomicFixnum.new(0)
        end
        counter.increment
      end

      # Update connection count for a host
      # @param host [String] the host name
      # @param delta [Integer] the change in connection count (positive or negative)
      # @return [void]
      def update_connections(host, delta)
        counter = @connections_per_host.compute_if_absent(host) do
          Concurrent::AtomicFixnum.new(0)
        end
        counter.update { |v| [v + delta, 0].max }
      end

      # Get the number of in-flight requests
      # @return [Integer]
      def in_flight_count
        @in_flight_requests.size
      end

      # Get a snapshot of in-flight requests
      # @return [Array<Request>] frozen array of requests
      def in_flight_requests
        @in_flight_requests.values.freeze
      end

      # Get total number of requests processed
      # @return [Integer]
      def total_requests
        @total_requests.value
      end

      # Get average request duration
      # @return [Float] average duration in seconds, or 0 if no requests
      def average_duration
        total = total_requests
        return 0.0 if total.zero?

        @total_duration.get / total.to_f
      end

      # Get total error count
      # @return [Integer]
      def error_count
        @error_count.value
      end

      # Get errors grouped by type
      # @return [Hash<Symbol, Integer>] frozen hash of error type to count
      def errors_by_type
        result = {}
        @errors_by_type.each_pair do |type, count|
          result[type] = count.value
        end
        result.freeze
      end

      # Get connections per host
      # @return [Hash<String, Integer>] frozen hash of host to connection count
      def connections_per_host
        result = {}
        @connections_per_host.each_pair do |host, count|
          result[host] = count.value
        end
        result.freeze
      end

      # Get a snapshot of all metrics
      # @return [Hash] hash with all metric values
      def to_h
        {
          "in_flight_count" => in_flight_count,
          "total_requests" => total_requests,
          "average_duration" => average_duration,
          "error_count" => error_count,
          "errors_by_type" => errors_by_type,
          "connections_per_host" => connections_per_host
        }
      end

      # Reset all metrics (useful for testing)
      # @return [void]
      def reset!
        @total_requests = Concurrent::AtomicFixnum.new(0)
        @error_count = Concurrent::AtomicFixnum.new(0)
        @total_duration = Concurrent::AtomicReference.new(0.0)
        @in_flight_requests = Concurrent::Map.new
        @errors_by_type = Concurrent::Map.new
        @connections_per_host = Concurrent::Map.new
      end
    end
  end
end
