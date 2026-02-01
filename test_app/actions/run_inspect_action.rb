# frozen_string_literal: true

class RunInspectAction
  def call(env)
    request = Rack::Request.new(env)
    return method_not_allowed_response unless request.post?

    # Clear the previous response
    InspectCallback.clear_response
    timeout = request.params["timeout"]&.to_f || 30.0
    http_method = request.params["method"] || "GET"
    url_param = request.params["url"] || "/test"
    raise_error_responses = request.params["raise_error_responses"] == "1"

    # Build the full URL
    port = ENV.fetch("PORT", "9292")
    url = if url_param.start_with?("http://", "https://")
      url_param
    else
      "http://localhost:#{port}#{url_param.start_with?("/") ? url_param : "/#{url_param}"}"
    end

    headers = begin
      JSON.parse(request.params["headers"]) if request.params["headers"]
    rescue JSON::ParserError, TypeError
      {}
    end

    body = request.params["body"]

    Sidekiq::AsyncHttp.request(
      http_method,
      url,
      callback: "InspectCallback",
      headers: headers,
      body: body,
      timeout: timeout,
      raise_error_responses: raise_error_responses
    )

    [204, {}, []]
  end

  private

  def method_not_allowed_response
    [405, {"Content-Type" => "text/plain"}, ["Method Not Allowed"]]
  end
end
