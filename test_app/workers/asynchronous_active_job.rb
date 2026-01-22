# frozen_string_literal: true

# Example ActiveJob worker that makes HTTP requests using asynchronous HTTP calls.
class AsynchronousActiveJob < ActiveJob::Base
  include Sidekiq::AsyncHttp::Job

  queue_as :default
  retry_on StandardError, wait: 1.second, attempts: 2

  on_completion do |response, method, url, timeout|
    logger.info("ActiveJob async request succeeded: #{method.upcase} #{url} - Status: #{response.status}")
    StatusReport.new("Asynchronous").complete!
  end

  on_error do |error, method, url, timeout|
    logger.error("ActiveJob async request failed: #{method.upcase} #{url} - Error: #{error.class_name} #{error.message}")
    StatusReport.new("Asynchronous").error!
  end

  def perform(method, url, timeout)
    async_request(method, url, timeout: timeout)
  end
end
