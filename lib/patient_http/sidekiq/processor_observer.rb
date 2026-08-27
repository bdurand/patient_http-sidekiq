# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Processor observer that records stats and maintains the crash-recovery
    # registry for one processor. The stats aggregator and task monitor are
    # shared across all processors in the process; the module owns them and
    # the monitor thread.
    #
    # Tasks are registered in the crash-recovery registry when the processor
    # accepts them, before Processor#enqueue returns, so a request always has
    # a durable record from the moment the caller hands it off. The entry is
    # removed when the request completes or when a Sidekiq job owns the
    # request again (the task was rejected or re-enqueued). When result
    # delivery fails (completion_failed), the entry is kept so the orphan
    # collector re-enqueues the request instead of losing it, unless the
    # failure is one that trying again cannot fix; see
    # +UNDELIVERABLE_RESULT_ERRORS+.
    class ProcessorObserver < PatientHttp::ProcessorObserver
      # Delivery failures that mean the result can never be delivered: the
      # payload cannot be serialized, so every re-enqueue would end the same
      # way. A request that fails with one of these is moved to the Sidekiq
      # dead set instead of being kept for crash recovery. Every other failure
      # is treated as temporary (Redis unavailable, for example) and keeps its
      # crash-recovery record.
      UNDELIVERABLE_RESULT_ERRORS = [
        JSON::GeneratorError,
        Encoding::UndefinedConversionError,
        Encoding::InvalidByteSequenceError,
        Encoding::CompatibilityError
      ].freeze

      attr_reader :task_monitor

      def initialize(processor, stats:, task_monitor:)
        @processor = processor
        @stats = stats
        @task_monitor = task_monitor
        @processor_name = processor.name
        @requeued_task_ids = Set.new
        @requeued_mutex = Mutex.new
      end

      def capacity_exceeded
        @stats.record_capacity_exceeded(processor_name: @processor_name)
      end

      def request_enqueued(request_task)
        task_monitor.register(request_task, processor_name: @processor_name)
        @stats.record_inflight_peak(inflight_after_enqueue, processor_name: @processor_name)
      end

      def request_rejected(request_task)
        task_monitor.unregister(request_task)
      end

      def request_requeued(request_task)
        task_monitor.unregister(request_task)
        # The re-enqueue path fires request_end after request_requeued, but
        # only for tasks that already started. Remember those tasks so that
        # request_end does not unregister a second time or record a completion
        # stat for a request that never completed. A task that never started
        # gets no request_end, so remembering it would leak the id forever.
        return unless request_task.started?

        @requeued_mutex.synchronize { @requeued_task_ids << request_task.id }
      end

      def request_end(request_task)
        requeued = @requeued_mutex.synchronize { @requeued_task_ids.delete?(request_task.id) }
        return if requeued

        task_monitor.unregister(request_task)
        @stats.record_request(request_task.response&.status, request_task.duration, processor_name: @processor_name)
      end

      def request_error(error)
        error_type = error.is_a?(PatientHttp::Error) ? error.error_type : :exception
        @stats.record_error(error_type, processor_name: @processor_name)
      end

      def completion_failed(request_task, error)
        if undeliverable_result?(error) && kill_job(request_task, error)
          # The request itself finished and nothing will deliver its result,
          # so record it and drop its crash-recovery entry.
          task_monitor.unregister(request_task)
          @stats.record_request(request_task.response&.status, request_task.duration, processor_name: @processor_name)
          @stats.record_error(:undeliverable_result, processor_name: @processor_name)
          PatientHttp::Sidekiq.configuration.logger&.error(
            "[PatientHttp::Sidekiq] Result for request #{request_task.id} can never be delivered; " \
            "moved its job to the dead set: #{error.class} - #{error_message(error)}"
          )
          return
        end

        # Keep the crash-recovery registry entry: the orphan collector will
        # re-enqueue the request once its heartbeat goes stale.
        @stats.record_error(:completion_failed, processor_name: @processor_name)
        PatientHttp::Sidekiq.configuration.logger&.error(
          "[PatientHttp::Sidekiq] Result delivery failed for request #{request_task.id}; " \
          "leaving crash-recovery record for re-enqueue: #{error.class} - #{error_message(error)}"
        )
      end

      private

      # The number of requests the processor holds once it accepts the request
      # being announced. The count only rises when a request is accepted, so
      # sampling it here catches every high-water mark.
      #
      # The announcement is made before the task is counted, so the task itself
      # is added. A task announced when the processor is already full is
      # rejected right after, so the count is held to the processor's capacity.
      #
      # @return [Integer]
      def inflight_after_enqueue
        [@processor.total_count + 1, @processor.config.max_connections].min
      end

      # Whether an error means the result can never be delivered. The cause
      # chain is examined as well, because the failure is usually raised while
      # the result is being written to Redis.
      #
      # @param error [Exception] the delivery failure
      # @return [Boolean]
      def undeliverable_result?(error)
        while error
          return true if UNDELIVERABLE_RESULT_ERRORS.any? { |error_class| error.is_a?(error_class) }

          error = error.cause
        end

        false
      end

      # Move a request's job to the Sidekiq dead set, where it can be
      # inspected and retried by hand.
      #
      # Sidekiq's API is loaded on demand because loading it eagerly fails on
      # some supported Sidekiq versions. A job that cannot be moved reports
      # false, so the caller keeps the crash-recovery record rather than
      # dropping the request.
      #
      # @param request_task [RequestTask] the request task
      # @param error [Exception] the delivery failure
      # @return [Boolean] whether the job was moved
      def kill_job(request_task, error)
        require "sidekiq/api"

        job = dead_job(request_task.task_handler.sidekiq_job, error)
        ::Sidekiq::DeadSet.new.kill(JSON.generate(job), notify_failure: true, ex: error)
        true
      rescue LoadError, StandardError => e
        PatientHttp::Sidekiq.configuration.logger&.error(
          "[PatientHttp::Sidekiq] Failed to move request #{request_task.id} to the dead set: #{e.class} - #{error_message(e)}"
        )
        false
      end

      # Build the job record for the dead set. The failure fields are the ones
      # Sidekiq writes when a job dies on its own, so the entry reads the same
      # in the Web UI. A directly executed request has no job id yet, so it is
      # given one; the Web UI identifies dead entries by it.
      #
      # @param job [Hash] the Sidekiq job hash
      # @param error [Exception] the delivery failure
      # @return [Hash] the job record to store
      def dead_job(job, error)
        job.merge(
          "jid" => job["jid"] || SecureRandom.hex(12),
          "failed_at" => Time.now.to_f,
          "error_class" => error.class.name,
          "error_message" => error_message(error)
        )
      end

      # An error message that is safe to serialize and to log. A message that
      # reports a byte the result could not be serialized with holds that byte
      # itself, which would fail the same way the result did.
      #
      # @param error [Exception] the error
      # @return [String] the message with any invalid bytes replaced
      def error_message(error)
        message = error.message.to_s
        message = message.dup.force_encoding(Encoding::UTF_8) if message.encoding == Encoding::BINARY
        message.scrub
      end
    end
  end
end
