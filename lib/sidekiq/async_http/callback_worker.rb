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

    # Perform the callback invocation.
    #
    # @param result_data [Hash] Serialized Response or Error data
    # @param result_type [String] "response" or "error" indicating the type of result
    # @param callback_service_name [String] Fully qualified callback service class name
    def perform(result_data, result_type, callback_service_name)
      # Deserialize based on explicit type
      result = if result_type == "response"
        Response.load(result_data)
      else
        Error.load(result_data)
      end

      # Invoke global callbacks first
      if result.is_a?(Response)
        Sidekiq::AsyncHttp.invoke_completion_callbacks(result)
      else
        Sidekiq::AsyncHttp.invoke_error_callbacks(result)
      end

      # Instantiate and invoke callback service
      callback_service_class = ClassHelper.resolve_class_name(callback_service_name)
      callback_service = callback_service_class.new

      if result.is_a?(Response)
        callback_service.on_complete(result)
      else
        callback_service.on_error(result)
      end
    end
  end
end
