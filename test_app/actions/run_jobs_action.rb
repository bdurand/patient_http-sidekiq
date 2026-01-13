# frozen_string_literal: true

class RunJobsAction
  def call(env)
    request = Rack::Request.new(env)
    return method_not_allowed_response unless request.post?

    count = request.params["count"].to_i.clamp(1, 1000)
    delay = request.params["delay"].to_f
    timeout = request.params["timeout"].to_f
    randomize = request.params["randomize"] == "true"

    # Build the test URL for this application
    port = ENV.fetch("PORT", "9292")
    test_url = "http://localhost:#{port}/test?delay=#{delay}"
    test_url += "&randomize=true" if randomize

    count.times do
      ExampleWorker.perform_async("GET", test_url, timeout, delay)
    end
    [204, {}, []]
  end

  private

  def method_not_allowed_response
    [405, {"Content-Type" => "text/plain"}, ["Method Not Allowed"]]
  end
end
