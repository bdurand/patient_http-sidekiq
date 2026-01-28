# frozen_string_literal: true

# Example ActiveJob worker that makes HTTP requests using asynchronous HTTP calls.
class AsynchronousActiveJob < ActiveJob::Base
  include Sidekiq::AsyncHttp::Job

  queue_as :default
  retry_on StandardError, wait: 1.second, attempts: 2

  on_completion do |response|
    method = response.http_method
    url = response.url
    logger.info("ActiveJob async request succeeded: #{method.upcase} #{url} - Status: #{response.status} (#{response.callback_args[:uuid]})")
    StatusReport.new("Asynchronous").complete!
  end

  on_error do |error|
    method = error.http_method
    url = error.url
    logger.error("ActiveJob async request failed: #{method.upcase} #{url} - Error: #{error.error_class.name} #{error.message} (#{error.callback_args[:uuid]})")
    StatusReport.new("Asynchronous").error!
  end

  def perform(method, url, timeout)
    async_request(method, url, timeout: timeout, callback_args: {uuid: SecureRandom.uuid})
  end
end
