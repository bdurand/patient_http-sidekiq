# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Stores the current Sidekiq job for each thread.
    #
    # Code that runs in a job reads the job from this class instead of
    # receiving it as an argument. RequestWorker uses the job to re-enqueue a
    # request.
    class Context
      # The current job for each thread, keyed by thread object ID.
      @jobs = Concurrent::Map.new

      # Sidekiq server middleware that sets the current job.
      #
      # The middleware sets the job only for RequestWorker jobs, because no
      # other worker needs it.
      class Middleware
        include ::Sidekiq::ServerMiddleware

        # Runs a job. Sets it as the current job if it's a RequestWorker job.
        #
        # @param worker [Object] The worker instance.
        # @param job [Hash] The Sidekiq job Hash.
        # @param queue [String] The queue name.
        # @yield The block that runs the job.
        # @return [Object] The return value of the block.
        def call(worker, job, queue)
          # Only set context for RequestWorker (the only worker that needs it)
          if job["class"] == PatientHttp::Sidekiq::RequestWorker.name
            PatientHttp::Sidekiq::Context.with_job(job) do
              yield
            end
          else
            yield
          end
        end
      end

      class << self
        # Returns the current Sidekiq job for this thread.
        #
        # @return [Hash, nil] The job Hash, or `nil` if no job is set.
        def current_job
          @jobs[Thread.current.object_id]
        end

        # Sets the current job for the duration of a block.
        #
        # @param job [Hash] The Sidekiq job Hash.
        # @yield The block to run.
        # @return [Object] The return value of the block.
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
end
