# frozen_string_literal: true

# Returns the last Inspect response stored in Redis.
#
# Used by the inspect test page for polling to display the response.
class InspectStatusAction
  def call(_env)
    response = InspectCallback.get_response

    [
      200,
      {"Content-Type" => "application/json; charset=utf-8"},
      [JSON.generate({response: response})]
    ]
  end
end
