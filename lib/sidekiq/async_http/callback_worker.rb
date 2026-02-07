# frozen_string_literal: true

module Sidekiq
  module AsyncHttp
    # Sidekiq worker that invokes callback services for HTTP request results.
    #
    # This worker receives serialized Response or Error data and invokes the
    # appropriate callback service method (+on_complete+ or +on_error+).
    #
    # Callback services are plain Ruby classes that define +on_complete+ and +on_error+
    # instance methods:
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
      include Sidekiq::Job

      # Clean up externally stored payloads when job exhausts all retries.
      # This prevents orphaned payload files when callbacks fail permanently.
      sidekiq_retries_exhausted do |job, _exception|
        data = job["args"][0]

        begin
          ExternalStorage.delete(data)
        rescue => e
          Sidekiq::AsyncHttp.configuration.logger&.warn(
            "[Sidekiq::AsyncHttp] Failed to delete stored payload for dead job: #{e.message}"
          )
        end
      end

      # Perform the callback invocation.
      #
      # @param data [Hash] Response or Error data (possibly a storage reference)
      # @param result_type [String] "response" or "error" indicating the type of result
      # @param callback_service_name [String] Fully qualified callback service class name
      def perform(data, result_type, callback_service_name)
        callback_service_class = ClassHelper.resolve_class_name(callback_service_name)
        callback_service = callback_service_class.new

        # Fetch from external storage if needed
        ref_data = AsyncHttp.external_storage.storage_ref?(data) ? data : nil
        actual_data = ref_data ? AsyncHttp.external_storage.fetch(data) : data
        actual_data = Sidekiq::AsyncHttp.configuration.decrypt(actual_data)

        begin
          if result_type == "response"
            response = Response.load(actual_data)
            Sidekiq::AsyncHttp.invoke_completion_callbacks(response)
            callback_service.on_complete(response)
          elsif result_type == "error"
            error = Error.load(actual_data)
            Sidekiq::AsyncHttp.invoke_error_callbacks(error)
            callback_service.on_error(error)
          else
            raise ArgumentError, "Unknown result_type: #{result_type}"
          end
        ensure
          AsyncHttp.external_storage.delete(ref_data) if ref_data
        end
      end
    end
  end
end
