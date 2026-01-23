# frozen_string_literal: true

# Example worker that outputs the result to the tmp directory.
class ExampleWorker
  include Sidekiq::AsyncHttp::Job

  sidekiq_options retry: 1

  on_completion(encrypted_args: true) do |response, method, url, timeout, delay|
    path = write_response(response)
    Sidekiq.logger.info("ExampleWorker: Response written to #{path}")
  end

  on_error(encrypted_args: true) do |error, method, url, timeout, delay|
    Sidekiq.logger.error("ExampleWorker Error: #{error.inspect}\n#{error.backtrace.join("\n")}")
  end

  def perform(method, url)
    async_request(method, url)
  end

  private

  def write_response(response)
    tmp_dir = File.join(__dir__, "..", "tmp")
    Dir.mkdir(tmp_dir) unless Dir.exist?(tmp_dir)
    file_name = "response_#{response.request_id}#{response_extension(response)}"
    path = File.join(tmp_dir, file_name)
    File.binwrite(path, response.body)
    path
  end

  def response_extension(response)
    case response.content_type
    when /jpeg/
      ".jpg"
    when /png/
      ".png"
    when /gif/
      ".gif"
    when /svg/
      ".svg"
    when /webp/
      ".webp"
    when /pdf/
      ".pdf"
    when /csv/
      ".csv"
    when /yaml/, /yml/
      ".yml"
    when /zip/
      ".zip"
    when /html/
      ".html"
    when /json/
      ".json"
    when /xml/
      ".xml"
    when /text/
      ".txt"
    end
  end
end
