# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Sidekiq implementation of TaskHandler.
    #
    # Handles task lifecycle operations using Sidekiq for job management:
    # - Completion and error callbacks are triggered via CallbackWorker
    # - Large payloads are stored via ExternalStorage before enqueuing
    # - Job retry uses Sidekiq::Client.push
    class TaskHandler < PatientHttp::TaskHandler
      # @return [Hash] The Sidekiq job hash containing class, jid, args, etc.
      #   Exposed for TaskMonitor crash recovery serialization.
      attr_reader :sidekiq_job

      # @param sidekiq_job [Hash] The Sidekiq job hash with "class", "jid", "args", etc.
      def initialize(sidekiq_job)
        @sidekiq_job = sidekiq_job
      end

      # Trigger the completion callback with the response.
      #
      # Stores the response via ExternalStorage (for large payloads) and
      # enqueues a CallbackWorker to invoke the callback asynchronously.
      #
      # @param response [Response] the HTTP response object
      # @param callback [String] callback class name
      # @return [void]
      def on_complete(response, callback)
        data = store_if_needed(response.as_json)
        PatientHttp::Sidekiq.with_redis_pool do
          callback_worker.perform_async(data, "response", callback)
        end
        delete_stored_request_payload
      end

      # Trigger the error callback with the error.
      #
      # Stores the error via ExternalStorage (for large payloads) and
      # enqueues a CallbackWorker to invoke the callback asynchronously.
      #
      # @param error [Error] the error object
      # @param callback [String] callback class name
      # @return [void]
      def on_error(error, callback)
        data = store_if_needed(error.as_json)
        PatientHttp::Sidekiq.with_redis_pool do
          callback_worker.perform_async(data, "error", callback)
        end
        delete_stored_request_payload
      end

      # Re-enqueue the original Sidekiq job for retry.
      #
      # @return [String] the job ID
      def retry
        PatientHttp::Sidekiq.with_redis_pool do
          ::Sidekiq::Client.push(@sidekiq_job)
        end
      end

      # Return the job ID from the Sidekiq job.
      #
      # @return [String] job ID
      def job_id
        @sidekiq_job["jid"]
      end

      # Return the worker class from the Sidekiq job.
      #
      # @return [Class] worker class
      def worker_class
        PatientHttp::ClassHelper.resolve_class_name(@sidekiq_job["class"])
      end

      private

      # Returns CallbackWorker or a Sidekiq job setter that routes the callback
      # job to the same queue as the request job when a runtime queue was set
      # at enqueue time.
      def callback_worker
        queue = @sidekiq_job["patient_http_callback_queue"]
        if queue
          CallbackWorker.set(queue: queue)
        else
          CallbackWorker
        end
      end

      # Delete the externally stored request payload once the request has
      # completed. Until then the payload must remain fetchable because the
      # Sidekiq job hash referencing it can be re-pushed by Sidekiq retries,
      # processor shutdown retries, and crash recovery. Only applies to
      # RequestWorker jobs; other job types own their own arguments.
      def delete_stored_request_payload
        return unless @sidekiq_job["class"] == RequestWorker.name

        data = @sidekiq_job["args"]&.first
        return unless PatientHttp::ExternalStorage.storage_ref?(data)

        PatientHttp::Sidekiq.external_storage.delete(data)
      rescue => e
        PatientHttp::Sidekiq.configuration.logger&.warn(
          "[PatientHttp::Sidekiq] Failed to delete stored request payload: #{e.class.name} #{e.message}".strip
        )
      end

      def store_if_needed(data)
        encrypted = Sidekiq.encrypt(data)
        external_storage = PatientHttp::Sidekiq.external_storage
        if external_storage.enabled?
          external_storage.store(encrypted, max_size: PatientHttp::Sidekiq.configuration.payload_store_threshold)
        else
          encrypted
        end
      end
    end
  end
end
