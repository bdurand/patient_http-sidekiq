# frozen_string_literal: true

require "faraday"
require "faraday-sidekiq_async_http"

# Handles form submissions from the Faraday adapter test page.
#
# Supports two modes:
# - "sidekiq": Enqueues a FaradayRequestWorker to make the request from a Sidekiq job
# - "direct": Makes the Faraday request directly (outside Sidekiq context)
class RunFaradayAction
  def call(env)
    request = Rack::Request.new(env)
    return method_not_allowed_response unless request.post?

    # Clear the previous response
    FaradayRequestWorker.clear_response
    context = request.params["context"] || "sidekiq"
    timeout = request.params["timeout"]&.to_f || 30.0
    method = request.params["method"] || "GET"
    url_param = request.params["url"] || "/test"

    # Build the full URL
    port = ENV.fetch("PORT", "9292")
    url = if url_param.start_with?("http://", "https://")
      url_param
    else
      "http://localhost:#{port}#{url_param.start_with?("/") ? url_param : "/#{url_param}"}"
    end

    if context == "sidekiq"
      # Enqueue a worker to make the request from Sidekiq context
      FaradayRequestWorker.perform_async(method, url, timeout)
    else
      # Make the request directly (outside Sidekiq context)
      make_direct_request(method, url, timeout)
    end

    [204, {}, []]
  end

  private

  # Make a Faraday request directly (outside Sidekiq context).
  #
  # This demonstrates using the Faraday adapter with callback_args
  # when not running inside a Sidekiq job.
  #
  # @param method [String] HTTP method (e.g., "GET", "POST").
  # @param url [String] The URL to request.
  # @param timeout [Float] Request timeout in seconds.
  # @return [void]
  def make_direct_request(method, url, timeout)
    uri = URI.parse(url)
    base_url = "#{uri.scheme}://#{uri.host}:#{uri.port}"
    path = uri.path
    path += "?#{uri.query}" if uri.query

    connection = Faraday.new(url: base_url) do |f|
      f.adapter :sidekiq_async_http
    end

    connection.run_request(method.downcase.to_sym, path, nil, nil) do |req|
      req.options.timeout = timeout
      req.options.context = {
        sidekiq_async_http: Faraday::SidekiqAsyncHttp::Adapter.async_options(
          completion_worker: FaradayRequestWorker::CompletionCallback,
          error_worker: FaradayRequestWorker::ErrorCallback,
          callback_args: ["direct_request", Time.now.to_i]
        )
      }
    end
  end

  def method_not_allowed_response
    [405, {"Content-Type" => "text/plain"}, ["Method Not Allowed"]]
  end
end
