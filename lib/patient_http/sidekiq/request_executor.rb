# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Runs HTTP requests on a processor in the current process.
    class RequestExecutor
      class << self
        # Hands a request to a processor in the current process. RequestWorker
        # and direct execution call this method.
        #
        # When the request finishes, the callback service's +on_complete+ method
        # receives a Response. If the request fails, the +on_error+ method
        # receives an Error. A failure is a network error, a timeout, or a
        # non-2xx response when +raise_error_responses+ is +true+.
        #
        # When jobs run inline with <tt>Sidekiq::Testing.inline!</tt>, the
        # request runs synchronously instead.
        #
        # @param request [PatientHttp::Request] The HTTP request.
        # @param callback [Class, String] The callback service class, or its
        #   fully qualified name. The class must define +on_complete+ and
        #   +on_error+ instance methods.
        # @param sidekiq_job [Hash, nil] The Sidekiq job Hash, with +class+ and
        #   +args+ keys. If +nil+, uses Context.current_job, which requires
        #   Context::Middleware in the Sidekiq server middleware chain.
        # @param task_handler [PatientHttp::TaskHandler, nil] A task handler to
        #   use instead of one built from +sidekiq_job+. Direct execution passes
        #   a handler.
        # @param synchronous [Boolean] Whether to run the request synchronously.
        #   Intended for tests.
        # @param callback_args [#to_h, nil] The arguments to pass to the
        #   callback. Values must be JSON-native types: +nil+, +true+, +false+,
        #   String, Integer, Float, Array, or Hash. Hash keys are converted to
        #   strings. The callback reads the arguments from
        #   +response.callback_args+ or +error.callback_args+ with symbol or
        #   string keys.
        # @param raise_error_responses [Boolean] Whether to treat non-2xx
        #   responses as errors and call +on_error+ instead of +on_complete+.
        # @param request_id [String, nil] The request ID. If +nil+, a new UUID
        #   is generated.
        # @param processor_name [Symbol, String, nil] The name of the processor
        #   profile that runs the request. If +nil+, uses the processor set on
        #   the request, then +:default+.
        # @return [String] The request ID.
        # @raise [PatientHttp::UnknownProcessorError] If the processor profile
        #   isn't configured.
        # @raise [PatientHttp::NotRunningError] If the processor isn't running.
        # @raise [PatientHttp::MaxCapacityError] If the processor is at
        #   capacity.
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
