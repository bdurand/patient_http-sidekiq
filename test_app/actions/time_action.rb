# frozen_string_literal: true

# Returns the current time as JSON.
class TimeAction
  def call(env)
    time = Time.now.utc.iso8601
    headers = {"Api-Key" => env["HTTP_API_KEY"]}

    if env["HTTP_CONTENT_TYPE"]&.start_with?("application/json")
      [
        200,
        headers.merge("Content-Type" => "application/json; charset=utf-8"),
        [JSON.generate({time: time})]
      ]
    else
      [
        200,
        headers.merge("Content-Type" => "text/plain; charset=utf-8"),
        [time]
      ]
    end
  end
end
