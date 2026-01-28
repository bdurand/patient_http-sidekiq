# frozen_string_literal: true

# Example worker that outputs the result to the tmp directory.
class ExampleWorker
  include Sidekiq::AsyncHttp::Job

  sidekiq_options retry: 1

  class CompletionWorker
    include Sidekiq::Job

    sidekiq_options encrypted_args: :response

    def perform(response)
      response = Sidekiq::AsyncHttp::Response.load(response)
      method = response.callback_args[:method]
      url = response.callback_args[:url]
      path = write_response(response)
      Sidekiq.logger.info("ExampleWorker: Response written to #{path} for #{method.upcase} #{url}")
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

  class ErrorWorker
    include Sidekiq::Job

    sidekiq_options encrypted_args: :error_hash

    def perform(error_hash)
      error = Sidekiq::AsyncHttp::Error.load(error_hash)
      method = error.callback_args[:method]
      url = error.callback_args[:url]
      Sidekiq.logger.error("ExampleWorker: Request #{method.upcase} #{url} failed with error: #{error.error_class.name} #{error.message}")
    end
  end

  self.completion_callback_worker = CompletionWorker
  self.error_callback_worker = ErrorWorker

  def perform(method, url)
    async_request(method, url, callback_args: {method: method, url: url})
  end
end
