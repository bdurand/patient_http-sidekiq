# frozen_string_literal: true

class TestAction
  def call(env)
    request = Rack::Request.new(env)
    delay = request.params["delay"]&.to_f

    [
      200,
      {"Content-Type" => "text/plain; charset=utf-8"},
      StreamingBody.new(delay)
    ]
  end

  class StreamingBody
    def initialize(delay)
      @delay = delay
    end

    def each
      yield "start"
      yield "..."
      if @delay && @delay > 0
        sleep(@delay)
      end
      yield "end"
    end
  end
end
