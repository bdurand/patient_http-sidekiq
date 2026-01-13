# frozen_string_literal: true

class TestAction
  def call(env)
    request = Rack::Request.new(env)
    delay = request.params["delay"]&.to_f
    randomize = request.params["randomize"] == "true"

    [
      200,
      {"Content-Type" => "text/plain; charset=utf-8"},
      StreamingBody.new(delay, randomize)
    ]
  end

  class StreamingBody
    def initialize(delay, randomize = false)
      @delay = delay
      @randomize = randomize
    end

    def each
      yield "start"
      yield "..."
      if @delay > 0
        actual_delay = @randomize ? rand((@delay / 2)..(@delay * 1.5)) : @delay
        sleep(actual_delay) if actual_delay > 0
      end
      yield "end"
    end
  end
end
