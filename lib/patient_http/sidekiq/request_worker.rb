# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Sidekiq job that runs an HTTP request on a processor.
    #
    # The `PatientHttp` module methods, such as `PatientHttp.get`, enqueue this
    # job unless the request runs directly on a processor in the current
    # process. When the request finishes, a CallbackWorker job calls the
    # callback service's `on_complete` or `on_error` method.
    #
    # @api private
    class RequestWorker
      include ::Sidekiq::Job

      # Deletes the externally stored request payload when the job uses up all
      # of its retries. TaskHandler deletes the payload when the request
      # finishes, so this hook matters only for requests that never finish.
      sidekiq_retries_exhausted do |job, _exception|
        Sidekiq.external_storage.delete(job["args"][0])
      rescue => e
        PatientHttp::Sidekiq.configuration.logger&.warn(
          "[PatientHttp::Sidekiq] Failed to delete stored payload for dead job: #{e.class.name} #{e.message}".strip
        )
      end

      # Runs the HTTP request on a processor.
      #
      # @param data [Hash] The serialized request, or a reference to it in
      #   external storage. The request can be encrypted.
      # @param callback_service_name [String] The fully qualified callback
      #   service class name.
      # @param raise_error_responses [Boolean, nil] Whether to treat non-2xx
      #   responses as errors. If `nil`, uses the processor profile's
      #   `raise_error_responses` option.
      # @param callback_args [Hash, nil] The arguments to pass to the callback.
      # @param request_id [String, nil] The request ID.
      # @param processor_name [String, nil] The name of the processor profile
      #   that runs the request. If `nil`, uses the processor set on the
      #   request, then the default processor. Jobs enqueued by earlier
      #   versions of the gem don't have this argument.
      # @return [void]
      def perform(data, callback_service_name, raise_error_responses, callback_args, request_id, processor_name = nil)
        # Fetch from external storage if needed
        actual_data = PatientHttp::ExternalStorage.storage_ref?(data) ? Sidekiq.external_storage.fetch(data) : data
        actual_data = Sidekiq.decrypt(actual_data)

        request = PatientHttp::Request.load(actual_data)
        sidekiq_job = Sidekiq::Context.current_job

        # The stored payload must not be deleted here: this job hash is re-pushed
        # for Sidekiq retries (e.g. MaxCapacityError), processor shutdown retries,
        # and crash recovery, all of which need to fetch the payload again.
        # TaskHandler deletes it when the request completes.
        RequestExecutor.execute(
          request,
          callback: callback_service_name,
          raise_error_responses: raise_error_responses,
          callback_args: callback_args,
          sidekiq_job: sidekiq_job,
          request_id: request_id,
          processor_name: processor_name
        )
      end
    end
  end
end
