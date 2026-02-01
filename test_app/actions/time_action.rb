# frozen_string_literal: true

# Returns the current time as JSON.
class TimeAction
  def call(_env)
    [
      200,
      {"Content-Type" => "application/json; charset=utf-8"},
      [JSON.generate({time: Time.now.iso8601})]
    ]
  end
end
