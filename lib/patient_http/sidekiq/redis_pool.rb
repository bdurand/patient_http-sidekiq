# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Dedicated Redis connection pool for threads that the gem owns.
    #
    # The completion worker threads and the monitor thread have no Sidekiq
    # capsule, so their <tt>Sidekiq.redis</tt> calls use Sidekiq's small
    # internal pool, which has 10 connections and a 1-second checkout timeout.
    # Under load, threads wait on that pool, and checkout timeouts can lose
    # work. This pool uses the application's Sidekiq Redis configuration. It
    # handles all registry writes, stats writes, and job pushes from threads
    # that the gem owns.
    class RedisPool
      # The minimum pool size when the +redis_pool_size+ option isn't set.
      DEFAULT_MINIMUM_SIZE = 10

      # Creates a pool. The connections open on first use.
      #
      # @param config [Configuration] The gem configuration.
      def initialize(config)
        @config = config
        @pid = nil
        @pool = nil
        @mutex = Mutex.new
      end

      # Returns the connection pool. Creates the pool on first use. Creates a
      # new pool after a fork so that a child process doesn't share its
      # parent's connections.
      #
      # @return [ConnectionPool] The connection pool.
      def pool
        @mutex.synchronize do
          if @pool.nil? || @pid != ::Process.pid
            @pool = ::Sidekiq.default_configuration.new_redis_pool(size, "patient_http")
            @pid = ::Process.pid
          end
          @pool
        end
      end

      # Checks out a connection and yields it. The checkout uses the
      # +redis_pool_timeout+ option. After a connection failure, runs the block
      # once more with a new connection, as Sidekiq does.
      #
      # The retry runs the whole block again. If the block isn't idempotent,
      # such as counter increments that the server might already have applied,
      # pass <tt>retry_on_connection_error: false</tt> and handle the failure.
      #
      # @param retry_on_connection_error [Boolean] Whether to run the block
      #   again after a connection failure.
      # @yield [conn] The block that uses the connection.
      # @yieldparam conn [Object] The Redis connection.
      # @return [Object] The return value of the block.
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

      # Closes all connections and removes the pool.
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

      # Returns the pool size. Uses the +redis_pool_size+ option if it's set.
      # Otherwise, allows one connection for each completion thread plus
      # connections for the monitor thread and request registration, with a
      # minimum of DEFAULT_MINIMUM_SIZE.
      #
      # @return [Integer] The pool size.
      def size
        @config.redis_pool_size || [DEFAULT_MINIMUM_SIZE, @config.completion_threads + 3].max
      end
    end
  end
end
