# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Task handler that uses Sidekiq to deliver results and retry requests.
    #
    # - A CallbackWorker job delivers each result to the callback service.
    # - Large payloads are written to external storage before the job is
    #   enqueued.
    # - A retry pushes the original Sidekiq job again.
    class TaskHandler < PatientHttp::TaskHandler
      # @return [Hash] The Sidekiq job Hash, with `class`, `jid`, `args`, and
      #   other keys. TaskMonitor saves it for crash recovery.
      attr_reader :sidekiq_job

      # Creates a task handler for a Sidekiq job.
      #
      # @param sidekiq_job [Hash] The Sidekiq job Hash, with `class`, `jid`,
      #   `args`, and other keys.
      # @param config [PatientHttp::Configuration, nil] The configuration of the
      #   processor that runs the request. If `nil`, uses the base configuration.
      def initialize(sidekiq_job, config: nil)
        @sidekiq_job = sidekiq_job
        @config = config
      end

      # Enqueues a CallbackWorker job that calls the callback service's
      # `on_complete` method. A large response is written to external storage
      # first.
      #
      # @param response [PatientHttp::Response] The HTTP response.
      # @param callback [String] The callback service class name.
      # @return [void]
      def on_complete(response, callback)
        data = store_if_needed(response.as_json)
        PatientHttp::Sidekiq.with_redis_pool do
          callback_worker.perform_async(data, "response", callback)
        end
        delete_stored_request_payload
      end

      # Enqueues a CallbackWorker job that calls the callback service's
      # `on_error` method. A large error is written to external storage first.
      #
      # @param error [PatientHttp::Error] The error.
      # @param callback [String] The callback service class name.
      # @return [void]
      def on_error(error, callback)
        data = store_if_needed(error.as_json)
        PatientHttp::Sidekiq.with_redis_pool do
          callback_worker.perform_async(data, "error", callback)
        end
        delete_stored_request_payload
      end

      # Pushes the original Sidekiq job again.
      #
      # @return [String] The job ID.
      def retry
        PatientHttp::Sidekiq.with_redis_pool do
          ::Sidekiq::Client.push(@sidekiq_job)
        end
      end

      # Returns the Sidekiq job ID.
      #
      # @return [String, nil] The job ID.
      def job_id
        @sidekiq_job["jid"]
      end

      # Returns the worker class of the Sidekiq job.
      #
      # @return [Class] The worker class.
      def worker_class
        PatientHttp::ClassHelper.resolve_class_name(@sidekiq_job["class"])
      end

      private

      # Returns the job class for the callback job. If a queue was set with
      # `with_sidekiq_options`, returns a job setter that uses that queue.
      #
      # @return [Object] CallbackWorker, or a job setter for it.
      def callback_worker
        queue = @sidekiq_job["patient_http_callback_queue"]
        if queue
          CallbackWorker.set(queue: queue)
        else
          CallbackWorker
        end
      end

      # Deletes the externally stored request payload after the request
      # finishes. The payload must stay available until then, because Sidekiq
      # retries, processor shutdown retries, and crash recovery can push the
      # job again. Applies only to RequestWorker jobs, because other job types
      # manage their own arguments.
      #
      # @return [void]
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

      # Encrypts data and writes it to external storage if storage is enabled
      # and the data is larger than the `payload_store_threshold` option.
      #
      # @param data [Hash] The data.
      # @return [Hash] The encrypted data, or a reference to it in external
      #   storage.
      def store_if_needed(data)
        encrypted = Sidekiq.encrypt(data)
        external_storage = PatientHttp::Sidekiq.external_storage
        if external_storage.enabled?
          max_size = (@config || PatientHttp::Sidekiq.configuration).payload_store_threshold
          external_storage.store(encrypted, max_size: max_size)
        else
          encrypted
        end
      end
    end
  end
end
