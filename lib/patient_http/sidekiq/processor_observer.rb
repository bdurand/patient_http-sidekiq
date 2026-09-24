# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Processor observer that records stats and maintains the crash-recovery
    # registry for one processor. All processors in a process share the stats
    # aggregator and the task monitor. The PatientHttp::Sidekiq module owns
    # them and the monitor thread.
    #
    # The observer adds a request to the crash-recovery registry when the
    # processor accepts it, before Processor#enqueue returns. As a result, a
    # request has a durable record from the moment the caller hands it off.
    # The observer removes the record when the request finishes, or when a
    # Sidekiq job owns the request again because the request was rejected or
    # re-enqueued.
    #
    # If a result can't be delivered, the observer keeps the record so that the
    # orphan collector re-enqueues the request. The exception is a failure that
    # a retry can't fix; see UNDELIVERABLE_RESULT_ERRORS.
    class ProcessorObserver < PatientHttp::ProcessorObserver
      # Errors that mean a result can never be delivered because the payload
      # can't be serialized. Every re-enqueue would fail the same way, so the
      # request's job moves to the Sidekiq dead set instead of staying in the
      # crash-recovery registry. Any other delivery failure, such as Redis
      # being unavailable, is treated as temporary, and the crash-recovery
      # record is kept.
      UNDELIVERABLE_RESULT_ERRORS = [
        JSON::GeneratorError,
        Encoding::UndefinedConversionError,
        Encoding::InvalidByteSequenceError,
        Encoding::CompatibilityError
      ].freeze

      # @return [TaskMonitor] The in-flight request registry.
      attr_reader :task_monitor

      # Creates an observer for a processor.
      #
      # @param processor [PatientHttp::Processor] The processor to observe.
      # @param stats [Stats] The stats aggregator.
      # @param task_monitor [TaskMonitor] The in-flight request registry.
      def initialize(processor, stats:, task_monitor:)
        @processor = processor
        @stats = stats
        @task_monitor = task_monitor
        @processor_name = processor.name
        @requeued_task_ids = Set.new
        @requeued_mutex = Mutex.new
      end

      # Records that the processor refused a request because it was at
      # capacity.
      #
      # @return [void]
      def capacity_exceeded
        @stats.record_capacity_exceeded(processor_name: @processor_name)
      end

      # Adds a request to the crash-recovery registry and records the
      # processor's in-flight high-water mark.
      #
      # @param request_task [PatientHttp::RequestTask] The request task.
      # @return [void]
      def request_enqueued(request_task)
        task_monitor.register(request_task, processor_name: @processor_name)
        @stats.record_inflight_peak(inflight_after_enqueue, processor_name: @processor_name)
      end

      # Removes a rejected request from the crash-recovery registry. A Sidekiq
      # job owns the request again.
      #
      # @param request_task [PatientHttp::RequestTask] The request task.
      # @return [void]
      def request_rejected(request_task)
        task_monitor.unregister(request_task)
      end

      # Removes a re-enqueued request from the crash-recovery registry. A
      # Sidekiq job owns the request again.
      #
      # @param request_task [PatientHttp::RequestTask] The request task.
      # @return [void]
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

      # Removes a finished request from the crash-recovery registry and records
      # its stats.
      #
      # @param request_task [PatientHttp::RequestTask] The request task.
      # @return [void]
      def request_end(request_task)
        requeued = @requeued_mutex.synchronize { @requeued_task_ids.delete?(request_task.id) }
        return if requeued

        task_monitor.unregister(request_task)
        @stats.record_request(request_task.response&.status, request_task.duration, processor_name: @processor_name)
      end

      # Records a request error.
      #
      # @param error [PatientHttp::Error, Exception] The error.
      # @return [void]
      def request_error(error)
        error_type = error.is_a?(PatientHttp::Error) ? error.error_type : :exception
        @stats.record_error(error_type, processor_name: @processor_name)
      end

      # Handles a failure to deliver a request's result. If the result can
      # never be delivered, moves the request's job to the Sidekiq dead set.
      # Otherwise, keeps the crash-recovery record so that the orphan collector
      # re-enqueues the request.
      #
      # @param request_task [PatientHttp::RequestTask] The request task.
      # @param error [Exception] The delivery failure.
      # @return [void]
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

      # Returns the number of requests that the processor holds after it
      # accepts the request being announced. The count rises only when a
      # request is accepted, so sampling it here catches every high-water mark.
      #
      # The announcement comes before the processor counts the request, so this
      # method adds the request itself. If the processor is already full, it
      # rejects the request right after the announcement, so the count is
      # capped at the processor's capacity.
      #
      # @return [Integer] The number of requests.
      def inflight_after_enqueue
        [@processor.total_count + 1, @processor.config.max_connections].min
      end

      # Returns whether an error means the result can never be delivered. Also
      # checks the chain of causes, because the failure usually occurs while
      # the result is written to Redis.
      #
      # @param error [Exception] The delivery failure.
      # @return [Boolean] +true+ if the result can never be delivered.
      def undeliverable_result?(error)
        while error
          return true if UNDELIVERABLE_RESULT_ERRORS.any? { |error_class| error.is_a?(error_class) }

          error = error.cause
        end

        false
      end

      # Moves a request's job to the Sidekiq dead set, where you can inspect it
      # and retry it by hand.
      #
      # The Sidekiq API loads on demand, because loading it at startup fails on
      # some supported Sidekiq versions. If the job can't be moved, returns
      # +false+ so that the caller keeps the crash-recovery record instead of
      # dropping the request.
      #
      # @param request_task [PatientHttp::RequestTask] The request task.
      # @param error [Exception] The delivery failure.
      # @return [Boolean] +true+ if the job was moved.
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

      # Builds the job record for the dead set. The record has the same
      # failure fields that Sidekiq writes when a job dies, so the entry looks
      # the same in the Web UI. A request that ran directly has no job ID, so
      # this method assigns one. The Web UI identifies dead entries by job ID.
      #
      # @param job [Hash] The Sidekiq job Hash.
      # @param error [Exception] The delivery failure.
      # @return [Hash] The job record.
      def dead_job(job, error)
        job.merge(
          "jid" => job["jid"] || SecureRandom.hex(12),
          "failed_at" => Time.now.to_f,
          "error_class" => error.class.name,
          "error_message" => error_message(error)
        )
      end

      # Returns an error message that is safe to serialize and log. The message
      # for a serialization failure can include the invalid byte, which would
      # fail the same way that the result did.
      #
      # @param error [Exception] The error.
      # @return [String] The message, with invalid bytes replaced.
      def error_message(error)
        message = error.message.to_s
        message = message.dup.force_encoding(Encoding::UTF_8) if message.encoding == Encoding::BINARY
        message.scrub
      end
    end
  end
end
