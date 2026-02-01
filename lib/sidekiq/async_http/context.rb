# frozen_string_literal: true

require "concurrent"

module Sidekiq::AsyncHttp
  # Provides thread-safe context for Sidekiq jobs.
  #
  # This class manages the current Sidekiq job context using a thread-id keyed hash,
  # allowing async HTTP requests to access job information without it being passed explicitly.
  # Only RequestWorker needs this context for re-enqueueing jobs.
  class Context
    # Thread-safe hash keyed by thread object_id
    @jobs = Concurrent::Map.new

    # Sidekiq server middleware that sets the current job context.
    #
    # This middleware only activates for RequestWorker, which is the only
    # worker that needs access to the job context for re-enqueueing.
    class Middleware
      include Sidekiq::ServerMiddleware

      def call(worker, job, queue)
        # Only set context for RequestWorker (the only worker that needs it)
        if job["class"] == Sidekiq::AsyncHttp::RequestWorker.name
          Sidekiq::AsyncHttp::Context.with_job(job) do
            yield
          end
        else
          yield
        end
      end
    end

    class << self
      # Returns the current Sidekiq job hash from context.
      #
      # @return [Hash, nil] the current job hash or nil if no job context is set
      def current_job
        @jobs[Thread.current.object_id]
      end

      # Sets the current job context for the duration of the block.
      #
      # @param job [Hash] the Sidekiq job hash
      # @yield executes the block with the job context set
      # @return [Object] the return value of the block
      def with_job(job)
        thread_id = Thread.current.object_id
        previous_job = @jobs[thread_id]
        @jobs[thread_id] = job
        yield
      ensure
        if previous_job
          @jobs[thread_id] = previous_job
        else
          @jobs.delete(thread_id)
        end
      end
    end
  end
end
