# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Sidekiq worker for executing HTTP requests asynchronously.
    #
    # This worker is enqueued when calling +PatientHttp::Sidekiq.get+, +PatientHttp::Sidekiq.post+,
    # etc. It allows HTTP requests to be made from anywhere in your code (not just Sidekiq jobs)
    # while still processing them through the async HTTP processor.
    #
    # When the request completes, the specified callback service's +on_complete+ or +on_error+
    # method is invoked via CallbackWorker.
    #
    # @api private
    class RequestWorker
      include ::Sidekiq::Job

      # Clean up the externally stored request payload when the job exhausts all
      # retries. The payload is normally deleted by TaskHandler when the request
      # completes, so this only fires for requests that never made it that far.
      sidekiq_retries_exhausted do |job, _exception|
        Sidekiq.external_storage.delete(job["args"][0])
      rescue => e
        PatientHttp::Sidekiq.configuration.logger&.warn(
          "[PatientHttp::Sidekiq] Failed to delete stored payload for dead job: #{e.class.name} #{e.message}".strip
        )
      end

      # Perform the HTTP request.
      #
      # @param data [Hash] Request data (possibly a storage reference) with keys:
      #   - "http_method" [String] HTTP method (get, post, put, patch, delete)
      #   - "url" [String] The request URL
      #   - "headers" [Hash] Request headers
      #   - "body" [String, nil] Request body
      #   - "timeout" [Numeric, nil] Request timeout
      #   - "max_redirects" [Integer, nil] Maximum redirects to follow
      # @param callback_service_name [String] Fully qualified callback service class name
      # @param raise_error_responses [Boolean, nil] Whether to treat non-2xx responses as errors;
      #   nil is treated as false
      # @param callback_args [Hash, nil] Arguments to pass to the callback
      # @param request_id [String, nil] Unique request ID for tracking
      # @param processor_name [String, nil] Name of the processor profile to run the request
      #   on; nil (jobs enqueued by older versions) runs on the default processor
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
          processor_name: processor_name || "default"
        )
      end
    end
  end
end
