# frozen_string_literal: true

require "concurrent"
require "async"
require "async/http/client"
require "async/condition"
require "uri"

module Sidekiq
  module AsyncHttp
    # Backpressure error raised when connection pool is at capacity
    class BackpressureError < StandardError; end

    # Thread-safe connection pool for async HTTP clients
    class ConnectionPool
      attr_reader :config

      def initialize(config, metrics: nil)
        @config = config
        @metrics = metrics
        @clients = Concurrent::Map.new
        @connection_counts = Concurrent::Map.new
        @total_connections = Concurrent::AtomicFixnum.new(0)
        @last_access = Concurrent::Map.new
        @mutex = Mutex.new
        @capacity_condition = Async::Condition.new
        @drop_oldest_callback = nil
      end

      # Get a client for the given URI
      # @param uri [String, URI] the URI to get a client for
      # @return [Async::HTTP::Client] the HTTP client
      # @raise [BackpressureError] if at capacity and strategy is :raise
      def client_for(uri)
        parsed_uri = parse_uri(uri)
        host = host_key(parsed_uri)

        # Check if we have an existing client
        client = @clients[host]
        if client
          update_last_access(host)
          return client
        end

        # Need to create a new client - check limits
        @mutex.synchronize do
          # Double-check after acquiring lock
          client = @clients[host]
          if client
            update_last_access(host)
            return client
          end

          # Check capacity limits
          check_capacity!(host)

          # Create new client
          endpoint = Async::HTTP::Endpoint.parse(parsed_uri.to_s)
          client = Async::HTTP::Client.new(
            endpoint,
            protocol: @config.enable_http2 ? Async::HTTP::Protocol::HTTP2 : Async::HTTP::Protocol::HTTP1
          )

          # Cache the client
          @clients[host] = client
          increment_connections(host)
          update_last_access(host)

          client
        end
      end

      # Execute a block with a client for the given URI
      # @param uri [String, URI] the URI to get a client for
      # @yield [Async::HTTP::Client] the HTTP client
      # @return [Object] the result of the block
      def with_client(uri)
        client = client_for(uri)
        result = yield client
        result
      rescue => error
        # Log error but don't fail - let caller handle it
        raise error
      ensure
        # Signal that a connection slot might be available
        release_connection_slot if @config.backpressure_strategy == :block
      end

      # Set callback for dropping oldest request (for :drop_oldest strategy)
      # @param callback [Proc] callback that returns the oldest request ID to drop
      # @return [void]
      def on_drop_oldest(&callback)
        @drop_oldest_callback = callback
      end

      # Release a connection slot and signal waiting tasks
      # @return [void]
      def release_connection_slot
        @capacity_condition.signal
      end

      # Close idle connections that exceed the idle timeout
      # @return [Integer] number of connections closed
      def close_idle_connections
        closed_count = 0
        now = Time.now

        @clients.each_pair do |host, client|
          last_access = @last_access[host]
          next unless last_access

          idle_time = now - last_access
          if idle_time > @config.idle_connection_timeout
            @mutex.synchronize do
              # Double-check under lock
              last_access = @last_access[host]
              next unless last_access && (now - last_access) > @config.idle_connection_timeout

              # Close and remove the client
              client = @clients.delete(host)
              if client
                begin
                  client.close
                rescue
                  # Ignore errors during close
                end
                decrement_connections(host)
                @last_access.delete(host)
                closed_count += 1
              end
            end
          end
        end

        closed_count
      end

      # Close all connections for shutdown
      # @return [void]
      def close_all
        @mutex.synchronize do
          @clients.each_pair do |host, client|
            begin
              client.close
            rescue
              # Ignore errors during close
            end
            decrement_connections(host)
          end

          @clients.clear
          @connection_counts.clear
          @last_access.clear
          @total_connections.value = 0
        end
      end

      # Get statistics about the connection pool
      # @return [Hash] statistics hash
      def stats
        {
          "total_connections" => @total_connections.value,
          "connections_by_host" => connections_by_host,
          "cached_clients" => @clients.size
        }
      end

      private

      # Parse a URI string or object
      # @param uri [String, URI] the URI to parse
      # @return [URI] the parsed URI
      def parse_uri(uri)
        uri.is_a?(URI) ? uri : URI.parse(uri.to_s)
      end

      # Get the host key for caching
      # @param uri [URI] the parsed URI
      # @return [String] the host key (scheme://host:port)
      def host_key(uri)
        port = uri.port || ((uri.scheme == "https") ? 443 : 80)
        "#{uri.scheme}://#{uri.host}:#{port}"
      end

      # Update the last access time for a host
      # @param host [String] the host key
      # @return [void]
      def update_last_access(host)
        @last_access[host] = Time.now
      end

      # Check if we can create a new connection
      # @param host [String] the host key
      # @raise [BackpressureError] if at capacity and strategy is :raise
      # @return [void]
      def check_capacity!(host)
        max_retries = 10 # Prevent infinite loops in tests
        retries = 0

        loop do
          total = @total_connections.value

          if total >= @config.max_connections
            retries += 1
            if retries > max_retries && @config.backpressure_strategy != :raise
              raise BackpressureError, "Max retries exceeded waiting for connection slot"
            end

            handle_backpressure("Total connection limit reached (#{total}/#{@config.max_connections})")
            # If handle_backpressure returns (for :block or :drop_oldest), retry the check
            next
          end

          # Have capacity, break out of loop
          break
        end
      end

      # Handle backpressure according to configured strategy
      # @param message [String] error message
      # @raise [BackpressureError] if strategy is :raise
      # @return [void]
      def handle_backpressure(message)
        # Record backpressure event in metrics
        @metrics&.record_backpressure

        case @config.backpressure_strategy
        when :raise
          raise BackpressureError, message
        when :block
          # Wait for a connection to be released using Async::Condition
          # This will yield to other fibers until a slot becomes available
          @capacity_condition.wait
          # After waking up, retry by returning (caller will check capacity again)
          return
        when :drop_oldest
          # Drop the oldest in-flight request to make room
          if @drop_oldest_callback
            dropped_request_id = @drop_oldest_callback.call
            if dropped_request_id
              # Request was dropped, retry by returning
              return
            end
          end
          # If no callback or couldn't drop, raise error
          raise BackpressureError, "#{message} (unable to drop oldest request)"
        end
      end

      # Increment connection count for a host
      # @param host [String] the host key
      # @return [void]
      def increment_connections(host)
        counter = @connection_counts.compute_if_absent(host) do
          Concurrent::AtomicFixnum.new(0)
        end
        counter.increment
        @total_connections.increment
      end

      # Decrement connection count for a host
      # @param host [String] the host key
      # @return [void]
      def decrement_connections(host)
        counter = @connection_counts[host]
        if counter
          counter.decrement
          @total_connections.decrement
        end
      end

      # Get current connections by host
      # @return [Hash<String, Integer>] host to connection count mapping
      def connections_by_host
        result = {}
        @connection_counts.each_pair do |host, counter|
          result[host] = counter.value
        end
        result
      end
    end
  end
end
