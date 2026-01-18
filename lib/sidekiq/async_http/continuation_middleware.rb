# frozen_string_literal: true

module Sidekiq::AsyncHttp
  # Middleware to handle continuation jobs for async HTTP requests.
  #
  # This middleware processes Sidekiq jobs that are continuations of async HTTP requests,
  # invoking the appropriate callbacks based on whether the request completed successfully
  # or resulted in an error.
  class ContinuationMiddleware
    include Sidekiq::ServerMiddleware

    def call(worker, job, queue)
      continuation_type = job.dig("async_http_continuation")
      if continuation_type
        if continuation_type == "completion"
          Sidekiq::AsyncHttp.invoke_completion_callbacks(job["args"].first)
        elsif continuation_type == "error"
          Sidekiq::AsyncHttp.invoke_error_callbacks(job["args"].first)
        end
      end

      yield
    end
  end
end
