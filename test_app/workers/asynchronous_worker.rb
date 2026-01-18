# frozen_string_literal: true

# Example worker that makes HTTP requests using asynchronous HTTP calls.
class AsynchronousWorker
  include Sidekiq::AsyncHttp::Job

  sidekiq_options retry: 5

  sidekiq_retry_in { |count| 2 }

  on_completion(encrypted_args: true) do |response, method, url, timeout, delay|
    Sidekiq.logger.info("Asynchronous request succeeded: #{method.upcase} #{url} - Status: #{response.status}")
    StatusReport.new("AsynchronousWorker").complete!
  end

  on_error(encrypted_args: true) do |error, method, url, timeout, delay|
    Sidekiq.logger.error("Asynchronous request failed: #{method.upcase} #{url} - Error: #{error.message}")
    StatusReport.new("AsynchronousWorker").error!
  end

  def perform(method, url, timeout, delay)
    async_request(method, url, timeout: timeout)
  end
end
