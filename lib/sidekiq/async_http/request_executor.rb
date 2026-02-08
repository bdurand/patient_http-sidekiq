# frozen_string_literal: true

module Sidekiq
  module AsyncHttp
    # Helper methods for executing HTTP requests asynchronously.
    class RequestExecutor
      class << self
        # Execute the request directly on the async processor.
        #
        # This method enqueues the request directly to the async processor. It must be
        # called from within a Sidekiq job context (the sidekiq_job parameter is required).
        # Used internally by RequestWorker.
        #
        # When the request completes, the callback's +on_complete+ method is called with
        # a Response object. If an error occurs (network error, timeout, or non-2xx response
        # if raise_error_responses is true), the +on_error+ method is called with an Error object.
        #
        # @param request [Request] the HTTP request to execute
        # @param callback [Class, String] Callback service class with +on_complete+ and +on_error+
        #   instance methods, or its fully qualified class name.
        # @param sidekiq_job [Hash, nil] Sidekiq job hash with "class" and "args" keys.
        #   If not provided, uses Sidekiq::AsyncHttp::Context.current_job.
        #   This requires the Sidekiq::AsyncHttp::Context::Middleware to be added
        #   to the Sidekiq server middleware chain.
        # @param synchronous [Boolean] If true, runs the request inline (for testing).
        # @param callback_args [#to_h, nil] Arguments to pass to callback via the
        #   Response/Error object. Must respond to +to_h+ and contain only JSON-native types
        #   (nil, true, false, String, Integer, Float, Array, Hash). All hash keys will be
        #   converted to strings for serialization. Access via +response.callback_args+ or
        #   +error.callback_args+ using symbol or string keys.
        # @param raise_error_responses [Boolean] If true, treats non-2xx responses as errors
        #   and calls +on_error+ instead of +on_complete+. Defaults to false.
        # @param request_id [String, nil] Unique request ID for tracking. If nil, a new UUID
        #   will be generated.
        # @return [String] the request ID
        # @api private
        def execute(
          request,
          callback:,
          sidekiq_job: nil,
          synchronous: false,
          callback_args: nil,
          raise_error_responses: false,
          request_id: nil
        )
          sidekiq_job = validate_sidekiq_job(sidekiq_job)
          task_handler = SidekiqTaskHandler.new(sidekiq_job)

          config = Sidekiq::AsyncHttp.configuration

          task = AsyncHttpPool::RequestTask.new(
            request: request,
            task_handler: task_handler,
            callback: callback,
            callback_args: callback_args,
            raise_error_responses: raise_error_responses,
            id: request_id,
            default_max_redirects: config.max_redirects
          )

          # Run the request inline if Sidekiq::Testing.inline! is enabled
          if synchronous || async_disabled?
            AsyncHttpPool::SynchronousExecutor.new(
              task,
              config: config,
              on_complete: ->(response) { Sidekiq::AsyncHttp.invoke_completion_callbacks(response) },
              on_error: ->(error) { Sidekiq::AsyncHttp.invoke_error_callbacks(error) }
            ).call
            return task.id
          end

          # Check if processor is running
          processor = Sidekiq::AsyncHttp.processor
          unless processor&.running?
            raise AsyncHttpPool::NotRunningError.new("Cannot enqueue request: processor is not running")
          end

          processor.enqueue(task)

          task.id
        end

        private

        def validate_sidekiq_job(sidekiq_job)
          sidekiq_job ||= Sidekiq::AsyncHttp::Context.current_job

          raise ArgumentError.new("sidekiq_job is required") if sidekiq_job.nil?

          raise ArgumentError.new("sidekiq_job must be a Hash, got: #{sidekiq_job.class}") unless sidekiq_job.is_a?(Hash)

          raise ArgumentError.new("sidekiq_job must have 'class' key") unless sidekiq_job.key?("class")

          raise ArgumentError.new("sidekiq_job must have 'args' array") unless sidekiq_job["args"].is_a?(Array)

          sidekiq_job
        end

        def async_disabled?
          defined?(Sidekiq::Testing) && Sidekiq::Testing.inline?
        end
      end
    end
  end
end
