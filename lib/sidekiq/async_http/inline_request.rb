# frozen_string_literal: true

module Sidekiq::AsyncHttp
  # Executes an HTTP request inline (synchronously) within the current thread.
  # This is used when Sidekiq.testing mode is set to :inline.
  class InlineRequest
    include TimeHelper

    def initialize(request_task)
      @task = request_task
    end

    def request
      @task.request
    end

    def execute
      require "net/http"

      start_time = monotonic_time

      begin
        http_response = make_http_request(request)

        end_time = monotonic_time
        duration = end_time - start_time

        # Build response object
        response = Response.new(
          status: http_response.code.to_i,
          headers: http_response.to_hash.transform_values { |v| v.is_a?(Array) ? v.join(", ") : v },
          body: http_response.body,
          duration: duration,
          request_id: @task.id,
          url: request.url,
          http_method: request.http_method,
          callback_args: @task.callback_args
        )

        # Check if we should raise an error for non-2xx responses
        if @task.raise_error_responses && !response.success?
          http_error = HttpError.new(response)

          # Invoke error callback inline with HttpError
          @task.error_worker.new.perform(http_error)
        else
          # Invoke completion callback inline
          @task.completion_worker.new.perform(response)
        end
      rescue => e
        # Calculate duration
        end_time = monotonic_time
        duration = end_time - start_time

        # Build error object and invoke error callback inline
        error = RequestError.from_exception(
          e,
          request_id: @task.id,
          duration: duration,
          url: request.url,
          http_method: request.http_method,
          callback_args: @task.callback_args
        )
        @task.error_worker.new.perform(error)
      end

      @id
    end

    private

    # Make the HTTP request using Net::HTTP.
    #
    # @param request [Request] the request object
    # @return [Net::HTTPResponse] the HTTP response
    def make_http_request(request)
      uri = URI.parse(request.url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = request.connect_timeout if request.connect_timeout
      http.read_timeout = request.timeout if request.timeout
      http.request(construct_net_http_request(request))
    end

    # Construct the Net::HTTP request object.
    #
    # @param request [Request] the request object
    # @return [Net::HTTPRequest] the constructed request
    def construct_net_http_request(request)
      uri = URI.parse(request.url)

      request_class = case request.http_method
      when :get then Net::HTTP::Get
      when :post then Net::HTTP::Post
      when :put then Net::HTTP::Put
      when :patch then Net::HTTP::Patch
      when :delete then Net::HTTP::Delete
      else
        raise ArgumentError.new("Unsupported method: #{request.http_method}")
      end

      req = request_class.new(uri.request_uri)

      # Set headers
      request.headers.each do |key, value|
        req[key] = value
      end
      req["x-request-id"] = @task.id

      unless request.headers["user-agent"]
        user_agent = Sidekiq::AsyncHttp.configuration.user_agent&.to_s || RequestBuilder::DEFAULT_USER_AGENT
        req["user-agent"] = user_agent
      end

      # Set body if present
      req.body = request.body if request.body

      req
    end
  end
end
