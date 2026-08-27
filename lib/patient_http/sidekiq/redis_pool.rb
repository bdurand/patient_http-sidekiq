# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Dedicated Redis connection pool for the gem's own threads.
    #
    # The processor's completion worker threads and the task monitor thread
    # carry no Sidekiq capsule state, so plain `Sidekiq.redis` calls from them
    # fall through to Sidekiq's small internal pool (10 connections, 1 second
    # checkout timeout). Under load that pool becomes a serialization point
    # and checkout timeouts can lose work. This pool is built from the
    # application's own Sidekiq Redis configuration and is used for all
    # registry, stats, and job pushes made from gem-owned threads.
    class RedisPool
      DEFAULT_MINIMUM_SIZE = 10

      # @param config [Configuration] the gem configuration
      def initialize(config)
        @config = config
        @pid = nil
        @pool = nil
        @mutex = Mutex.new
      end

      # The underlying ConnectionPool, created lazily and rebuilt after a
      # process fork so child processes never share parent connections.
      #
      # @return [ConnectionPool]
      def pool
        @mutex.synchronize do
          if @pool.nil? || @pid != ::Process.pid
            @pool = ::Sidekiq.default_configuration.new_redis_pool(size, "patient_http")
            @pid = ::Process.pid
          end
          @pool
        end
      end

      # Check out a connection with the gem's checkout timeout and yield it.
      # A connection-level failure is retried once on a fresh checkout,
      # mirroring the retry Sidekiq itself performs.
      #
      # The retry replays the whole block, so callers whose block is not
      # idempotent (counter increments, anything the server may already have
      # applied before the connection dropped) must pass
      # +retry_on_connection_error: false+ and handle the failure themselves.
      #
      # @param retry_on_connection_error [Boolean] whether to replay the block
      #   once after a connection-level failure
      # @yield [conn] the Redis connection
      # @return [Object] the block's return value
      def with(retry_on_connection_error: true, &block)
        retryable = retry_on_connection_error
        begin
          pool.with(timeout: @config.redis_pool_timeout) do |conn|
            yield conn
          end
        rescue RedisClient::ConnectionError
          raise unless retryable
          retryable = false
          retry
        end
      end

      # Close all connections and drop the pool.
      #
      # @return [void]
      def shutdown
        @mutex.synchronize do
          @pool&.shutdown { |conn| conn.close }
          @pool = nil
          @pid = nil
        end
      end

      private

      # Pool size: explicit configuration wins; otherwise size it to cover the
      # completion worker threads plus the monitor thread and request
      # registration, with a sane floor.
      #
      # @return [Integer]
      def size
        @config.redis_pool_size || [DEFAULT_MINIMUM_SIZE, @config.completion_threads + 3].max
      end
    end
  end
end
