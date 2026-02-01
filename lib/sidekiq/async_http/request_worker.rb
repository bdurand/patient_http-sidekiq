# frozen_string_literal: true

module Sidekiq::AsyncHttp
  # Sidekiq worker for executing HTTP requests asynchronously.
  #
  # This worker is enqueued when calling +Sidekiq::AsyncHttp.get+, +Sidekiq::AsyncHttp.post+,
  # etc., or when calling +Request#async_execute+. It allows HTTP requests to be made from
  # anywhere in your code (not just Sidekiq jobs) while still processing them through the
  # async HTTP processor.
  #
  # When the request completes, the specified callback service's +on_complete+ or +on_error+
  # method is invoked via CallbackWorker.
  #
  # @api private
  class RequestWorker
    include Sidekiq::Job

    # Perform the HTTP request.
    #
    # @param request [Hash] Serialized request data with keys:
    #   - "http_method" [String] HTTP method (get, post, put, patch, delete)
    #   - "url" [String] The request URL
    #   - "headers" [Hash] Request headers
    #   - "body" [String, nil] Request body
    #   - "timeout" [Numeric, nil] Request timeout
    #   - "max_redirects" [Integer, nil] Maximum redirects to follow
    # @param callback_service_name [String] Fully qualified callback service class name
    # @param raise_error_responses [Boolean, nil] Whether to treat non-2xx responses as errors;
    #   defaults to the global config if nil
    # @param callback_args [Hash, nil] Arguments to pass to the callback
    # @param request_id [String, nil] Unique request ID for tracking
    # @return [void]
    def perform(request, callback_service_name, raise_error_responses, callback_args, request_id)
      request = Request.load(request)
      sidekiq_job = Sidekiq::AsyncHttp::Context.current_job

      request.execute(
        callback: callback_service_name,
        raise_error_responses: raise_error_responses,
        callback_args: callback_args,
        sidekiq_job: sidekiq_job,
        request_id: request_id
      )
    end
  end
end
