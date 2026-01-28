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

      uri = URI.parse(request.url)
      start_time = monotonic_time

      begin
        # Create HTTP client
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = request.connect_timeout if request.connect_timeout
        http.read_timeout = request.timeout if request.timeout

        # Create request
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

        # Set body if present
        req.body = request.body if request.body
        # Execute request
        http_response = http.request(req)

        # Calculate duration
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

        # Invoke completion callback inline
        @task.completion_worker.new.perform(response)
      rescue => e
        # Calculate duration
        end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        duration = end_time - start_time

        raise e unless @task.error_worker

        # Build error object and invoke error callback inline
        error = Error.from_exception(
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
  end
end
