# frozen_string_literal: true

module Sidekiq::AsyncHttp
  # Provides thread-local context for Sidekiq jobs.
  #
  # This class manages the current Sidekiq job context in a thread-safe manner,
  # allowing async HTTP requests to access job information without it being passed explicitly.
  class Context
    # Sidekiq server middleware that sets the current job context.
    #
    # This middleware should be added to the Sidekiq server middleware chain to enable
    # automatic job context tracking for async HTTP requests.
    class Middleware
      include Sidekiq::ServerMiddleware

      def call(worker, job, queue)
        Sidekiq::AsyncHttp::Context.with_job(job) do
          yield
        end
      end
    end

    class << self
      # Returns the current Sidekiq job hash from thread-local storage.
      #
      # @return [Hash, nil] the current job hash or nil if no job context is set
      def current_job
        job = Thread.current[:sidekiq_async_http_current_job]
        deep_copy(job) if job
      end

      # Sets the current job context for the duration of the block.
      #
      # @param job [Hash] the Sidekiq job hash
      # @yield executes the block with the job context set
      # @return [Object] the return value of the block
      def with_job(job)
        previous_job = Thread.current[:sidekiq_async_http_current_job]
        Thread.current[:sidekiq_async_http_current_job] = job
        yield
      ensure
        Thread.current[:sidekiq_async_http_current_job] = previous_job
      end

      private

      def deep_copy(obj)
        Marshal.load(Marshal.dump(obj))
      end
    end
  end
end
