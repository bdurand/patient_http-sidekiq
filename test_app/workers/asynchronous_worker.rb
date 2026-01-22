# frozen_string_literal: true

# Example worker that makes HTTP requests using asynchronous HTTP calls.
class AsynchronousWorker
  include Sidekiq::AsyncHttp::Job
  include Sidekiq::Throttled::Job

  sidekiq_options retry: 5
  sidekiq_throttle concurrency: {limit: 25}

  sidekiq_retry_in { |count| 2 }

  on_completion(encrypted_args: true) do |response, method, url, timeout, delay|
    Sidekiq.logger.info("Asynchronous request succeeded: #{method.upcase} #{url} - Status: #{response.status}")
    StatusReport.new("Asynchronous").complete!
  end

  on_error(encrypted_args: true) do |error, method, url, timeout, delay|
    Sidekiq.logger.error("Asynchronous request failed: #{method.upcase} #{url} - Error: #{error.class_name} #{error.message}")
    StatusReport.new("Asynchronous").error!
  end

  def perform(method, url, timeout)
    async_request(method, url, timeout: timeout)
  end
end
