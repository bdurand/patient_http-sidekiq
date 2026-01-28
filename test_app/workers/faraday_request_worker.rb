# frozen_string_literal: true

require "faraday"
require "faraday-sidekiq_async_http"

# Worker that makes HTTP requests using the Faraday sidekiq_async_http adapter.
#
# This worker demonstrates how to use the Faraday adapter from within
# a Sidekiq job context. The callbacks store the response in Redis
# for display in the test UI.
class FaradayRequestWorker
  include Sidekiq::Job

  REDIS_KEY = "test_app_faraday_response"

  class << self
    # Clear the stored response from Redis.
    #
    # @return [void]
    def clear_response
      Sidekiq.redis { |conn| conn.del(REDIS_KEY) }
    end

    # Store a response payload in Redis with 60-second expiry.
    #
    # @param payload [Hash] The response or error payload to store.
    # @return [void]
    def set_response(payload)
      Sidekiq.redis { |conn| conn.setex(REDIS_KEY, 60, JSON.pretty_generate(payload)) }
    end

    # Get the stored response from Redis.
    #
    # @return [String, nil] The JSON response string or nil if not present.
    def get_response
      Sidekiq.redis { |conn| conn.get(REDIS_KEY) }
    end

    # Build the Faraday connection with the sidekiq_async_http adapter.
    #
    # @param base_url [String] The base URL for the connection.
    # @return [Faraday::Connection] The configured Faraday connection.
    def build_connection(base_url)
      Faraday.new(url: base_url) do |f|
        f.adapter :sidekiq_async_http,
          completion_worker: CompletionCallback,
          error_worker: ErrorCallback
      end
    end
  end

  # Perform an async HTTP request via the Faraday adapter.
  #
  # @param method [String] HTTP method (e.g., "GET", "POST").
  # @param url [String] The full URL to request.
  # @param timeout [Float, nil] Request timeout in seconds.
  # @return [void]
  def perform(method, url, timeout)
    uri = URI.parse(url)
    base_url = "#{uri.scheme}://#{uri.host}:#{uri.port}"
    path = uri.path
    path += "?#{uri.query}" if uri.query

    connection = self.class.build_connection(base_url)

    connection.run_request(method.downcase.to_sym, path, nil, nil) do |req|
      req.options.timeout = timeout if timeout
      req.options.context = {
        sidekiq_async_http: {
          callback_args: {mode: "async", uuid: SecureRandom.uuid}
        }
      }
    end
  end

  # Callback worker for successful HTTP responses.
  class CompletionCallback
    include Sidekiq::Job

    def perform(response_hash)
      response = Sidekiq::AsyncHttp::Response.load(response_hash)
      FaradayRequestWorker.set_response(response: response.as_json)
    end
  end

  # Callback worker for HTTP errors.
  class ErrorCallback
    include Sidekiq::Job

    def perform(error_hash)
      error = Sidekiq::AsyncHttp::Error.load(error_hash)
      FaradayRequestWorker.set_response(error: error.as_json)
    end
  end
end
