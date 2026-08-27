# frozen_string_literal: true

class IndexAction
  PROCESSOR_OPTIONS_PLACEHOLDER = "<!-- PROCESSOR_OPTIONS -->"

  def call(env)
    [
      200,
      {"Content-Type" => "text/html; charset=utf-8"},
      [page]
    ]
  end

  private

  def page
    html = File.read(File.join(__dir__, "../views/index.html"))
    html.sub(PROCESSOR_OPTIONS_PLACEHOLDER, processor_options)
  end

  # The processor selector is built from the configured profiles so the form
  # always offers exactly the processors that are running.
  def processor_options
    AppConfig.processor_names.map do |name|
      max_connections = PatientHttp::Sidekiq.configuration.processor_config(name).max_connections
      "<option value=\"#{name}\">#{name} (max #{max_connections})</option>"
    end.join("\n          ")
  end
end
