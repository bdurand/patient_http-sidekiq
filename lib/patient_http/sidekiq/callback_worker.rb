# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Sidekiq job that calls a callback service with the result of an HTTP
    # request.
    #
    # The job receives a serialized Response or Error and calls the callback
    # service's +on_complete+ or +on_error+ method. A callback service is a
    # Ruby class that defines both methods as instance methods.
    #
    # @example Callback service
    #   class MyCallback
    #     def on_complete(response)
    #       # Handle successful response
    #       User.find(response.callback_args[:user_id]).update!(data: response.json)
    #     end
    #
    #     def on_error(error)
    #       # Handle request error
    #       Rails.logger.error("Request failed: #{error.message}")
    #     end
    #   end
    #
    # @api private
    class CallbackWorker
      include ::Sidekiq::Job

      # When the job uses up all of its retries, calls the
      # +on_retries_exhausted+ handler for an error result. Then deletes the
      # externally stored payload so that it isn't left behind.
      sidekiq_retries_exhausted do |job, _exception|
        data = job["args"][0]
        result_type = job["args"][1]

        begin
          handler = PatientHttp::Sidekiq.configuration.on_retries_exhausted
          if handler && result_type == "error"
            actual_data = if Sidekiq.external_storage.storage_ref?(data)
              Sidekiq.external_storage.fetch(data)
            else
              data
            end
            actual_data = Sidekiq.decrypt(actual_data)
            error = PatientHttp::Error.load(actual_data)
            handler.call(error)
          end
        rescue => e
          PatientHttp::Sidekiq.configuration.logger&.warn(
            "[PatientHttp::Sidekiq] on_retries_exhausted handler failed: #{e.class.name} #{e.message}".strip
          )
        end

        begin
          Sidekiq.external_storage.delete(data)
        rescue => e
          PatientHttp::Sidekiq.configuration.logger&.warn(
            "[PatientHttp::Sidekiq] Failed to delete stored payload for dead job: #{e.class.name} #{e.message}".strip
          )
        end
      end

      # Calls the callback service with the result.
      #
      # @param data [Hash] The serialized Response or Error, or a reference to
      #   it in external storage. The data can be encrypted.
      # @param result_type [String] The result type: +"response"+ or +"error"+.
      # @param callback_service_name [String] The fully qualified callback
      #   service class name.
      # @return [void]
      # @raise [ArgumentError] If +result_type+ isn't valid.
      def perform(data, result_type, callback_service_name)
        callback_service_class = PatientHttp::ClassHelper.resolve_class_name(callback_service_name)
        callback_service = callback_service_class.new

        # Fetch from external storage if needed
        ref_data = Sidekiq.external_storage.storage_ref?(data) ? data : nil
        actual_data = ref_data ? Sidekiq.external_storage.fetch(data) : data
        actual_data = Sidekiq.decrypt(actual_data)

        if result_type == "response"
          response = PatientHttp::Response.load(actual_data)
          PatientHttp::Sidekiq.invoke_completion_callbacks(response)
          callback_service.on_complete(response)
        elsif result_type == "error"
          error = PatientHttp::Error.load(actual_data)
          PatientHttp::Sidekiq.invoke_error_callbacks(error)
          callback_service.on_error(error)
        else
          raise ArgumentError, "Unknown result_type: #{result_type}"
        end

        # Only delete the stored payload after the callback succeeds so that
        # Sidekiq retries can still fetch it. Failed jobs are cleaned up by
        # the sidekiq_retries_exhausted hook.
        Sidekiq.external_storage.delete(ref_data) if ref_data
      end
    end
  end
end
