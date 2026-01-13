# frozen_string_literal: true

class IndexAction
  def call(env)
    [
      200,
      { "Content-Type" => "text/html; charset=utf-8" },
      [File.read(File.join(__dir__, "../views/index.html"))]
    ]
  end
end
