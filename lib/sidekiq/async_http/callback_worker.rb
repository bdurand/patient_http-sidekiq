# frozen_string_literal: true

module Sidekiq::AsyncHttp
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
      result = job["args"][0]
      result_type = job["args"][1]

      begin
        unstore_payload(result, result_type)
      rescue => e
        Sidekiq::AsyncHttp.configuration.logger&.warn(
          "[Sidekiq::AsyncHttp] Failed to unstore payload for dead job: #{e.message}"
        )
      end
    end

    class << self
      # Unstore a payload based on result type.
      #
      # @param result [Hash] Serialized Response or Error data
      # @param result_type [String] "response" or "error"
      # @return [void]
      def unstore_payload(result, result_type)
        if result_type == "response"
          response = Response.load(result)
          response.unstore
        elsif result_type == "error"
          error = Error.load(result)
          error.response.unstore if error.is_a?(HttpError)
        end
      end
    end

    # Perform the callback invocation.
    #
    # @param result [Hash] Serialized Response or Error data
    # @param result_type [String] "response" or "error" indicating the type of result
    # @param callback_service_name [String] Fully qualified callback service class name
    def perform(result, result_type, callback_service_name)
      callback_service_class = ClassHelper.resolve_class_name(callback_service_name)
      callback_service = callback_service_class.new

      if result_type == "response"
        response = Response.load(result)
        begin
          Sidekiq::AsyncHttp.invoke_completion_callbacks(response)
          callback_service.on_complete(response)
        ensure
          response.unstore
        end
      elsif result_type == "error"
        error = Error.load(result)
        begin
          Sidekiq::AsyncHttp.invoke_error_callbacks(error)
          callback_service.on_error(error)
        ensure
          error.response.unstore if error.is_a?(HttpError)
        end
      else
        raise ArgumentError, "Unknown result_type: #{result_type}"
      end
    end
  end
end
