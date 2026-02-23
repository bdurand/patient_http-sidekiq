# frozen_string_literal: true

class RequestAction
  def call(env)
    rack_request = Rack::Request.new(env)
    headers = rack_request.env.select { |k, _| k.start_with?("HTTP_") }.transform_keys do |k|
      k.sub(/^HTTP_/, "").split("_").map(&:downcase).join("-")
    end

    request = PatientHttp::Request.new(
      rack_request.request_method.downcase.to_sym,
      rack_request.url,
      headers: headers,
      body: rack_request.body&.read
    )

    [200, {"Content-Type" => "application/json"}, [JSON.dump(request.as_json)]]
  end
end
