# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Helper methods for executing HTTP requests asynchronously.
    class RequestExecutor
      class << self
        # Execute the request directly on the async processor.
        #
        # This method enqueues the request directly to the async processor. Used internally
        # by RequestWorker.
        #
        # When the request completes, the callback's +on_complete+ method is called with
        # a Response object. If an error occurs (network error, timeout, or non-2xx response
        # if raise_error_responses is true), the +on_error+ method is called with an Error object.
        #
        # @param request [Request] the HTTP request to execute
        # @param callback [Class, String] Callback service class with +on_complete+ and +on_error+
        #   instance methods, or its fully qualified class name.
        # @param sidekiq_job [Hash, nil] Sidekiq job hash with "class" and "args" keys.
        #   If not provided, uses PatientHttp::Sidekiq::Context.current_job.
        #   This requires the PatientHttp::Sidekiq::Context::Middleware to be added
        #   to the Sidekiq server middleware chain.
        # @param task_handler [PatientHttp::TaskHandler, nil] A prebuilt task handler.
        #   When provided, the sidekiq_job parameter is ignored and no handler is
        #   built from it. Used for direct execution on the local processor.
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
        # @param processor_name [Symbol, String, nil] Name of the processor profile to run
        #   the request on. Defaults to the request's own processor name or :default.
        # @return [String] the request ID
        # @api private
        def execute(
          request,
          callback:,
          sidekiq_job: nil,
          task_handler: nil,
          synchronous: false,
          callback_args: nil,
          raise_error_responses: false,
          request_id: nil,
          processor_name: nil
        )
          task_handler ||= TaskHandler.new(validate_sidekiq_job(sidekiq_job))
          config = PatientHttp::Sidekiq.configuration

          # Look up the named processor and the effective configuration for its
          # profile, so per-processor overrides apply to the request itself.
          # A running processor already holds the built profile configuration.
          name = (processor_name || request.processor || :default).to_sym
          processor = PatientHttp::Sidekiq.processor(name)
          profile_declared = config.processor_profiles.key?(name)
          task_config = processor&.config || (profile_declared ? config.processor_config(name) : config)

          task = PatientHttp::RequestTask.new(
            request: request,
            task_handler: task_handler,
            callback: callback,
            callback_args: callback_args,
            raise_error_responses: raise_error_responses,
            id: request_id,
            default_max_redirects: task_config.max_redirects
          )

          # Run the request inline if Sidekiq::Testing.inline! is enabled
          if synchronous || async_disabled?
            PatientHttp::SynchronousExecutor.new(
              task,
              config: task_config,
              on_complete: ->(response) { PatientHttp::Sidekiq.invoke_completion_callbacks(response) },
              on_error: ->(error) { PatientHttp::Sidekiq.invoke_error_callbacks(error) }
            ).call
            return task.id
          end

          # An unknown name raises so the job lands in Sidekiq's retry
          # mechanism instead of being dropped; this covers rolling deploys
          # where an old process has not configured a new profile yet.
          if processor.nil? && !profile_declared
            raise PatientHttp::UnknownProcessorError.new("No processor profile configured for #{name.inspect}")
          end

          unless processor&.running?
            raise PatientHttp::NotRunningError.new("Cannot enqueue request: processor is not running")
          end

          # Advisory capacity check before enqueueing. A real enqueue pays for
          # durable registration before the authoritative capacity check, so a
          # full processor would cost several Redis round trips just to be
          # rejected. This peek rejects for free; the race where capacity fills
          # after the peek falls through to the normal rejection path.
          unless processor.capacity_available?
            PatientHttp::Sidekiq.stats.record_capacity_exceeded(processor_name: name)
            raise PatientHttp::MaxCapacityError.new(
              "Cannot enqueue request: processor #{name} is at max capacity (#{processor.config.max_connections} connections)"
            )
          end

          processor.enqueue(task)

          task.id
        end

        private

        def validate_sidekiq_job(sidekiq_job)
          sidekiq_job ||= PatientHttp::Sidekiq::Context.current_job

          raise ArgumentError.new("sidekiq_job is required") if sidekiq_job.nil?

          raise ArgumentError.new("sidekiq_job must be a Hash, got: #{sidekiq_job.class}") unless sidekiq_job.is_a?(Hash)

          raise ArgumentError.new("sidekiq_job must have 'class' key") unless sidekiq_job.key?("class")

          raise ArgumentError.new("sidekiq_job must have 'args' array") unless sidekiq_job["args"].is_a?(Array)

          sidekiq_job
        end

        def async_disabled?
          defined?(::Sidekiq::Testing) && ::Sidekiq::Testing.inline?
        end
      end
    end
  end
end
