# frozen_string_literal: true

class InspectAction
  def call(_env)
    [
      200,
      {"Content-Type" => "text/html; charset=utf-8"},
      [File.read(File.join(__dir__, "../views/inspect.html"))]
    ]
  end
end
