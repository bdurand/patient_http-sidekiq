# frozen_string_literal: true

require "net/http"
require "uri"

# Example ActiveJob worker that makes HTTP requests using synchronous HTTP calls.
class SynchronousActiveJob < ActiveJob::Base
  queue_as :default
  retry_on StandardError, wait: 1.seconds, attempts: 2

  def perform(method, url, timeout)
    status_report = StatusReport.new("Synchronous")
    begin
      response = execute_request(method, url, timeout)
      logger.info("Synchronous ActiveJob request succeeded: #{method.upcase} #{url} - Status: #{response.code}")
      status_report.complete!
    rescue => e
      logger.error("Synchronous ActiveJob request failed: #{method.upcase} #{url} - Error: #{e.message}")
      status_report.error!
    end
  end

  private

  def execute_request(method, url, timeout)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = timeout
    http.read_timeout = timeout
    http.write_timeout = timeout

    request = case method.to_s.upcase
    when "GET"
      Net::HTTP::Get.new(uri.request_uri)
    when "POST"
      Net::HTTP::Post.new(uri.request_uri)
    when "PUT"
      Net::HTTP::Put.new(uri.request_uri)
    when "DELETE"
      Net::HTTP::Delete.new(uri.request_uri)
    when "HEAD"
      Net::HTTP::Head.new(uri.request_uri)
    when "PATCH"
      Net::HTTP::Patch.new(uri.request_uri)
    else
      raise ArgumentError, "Unsupported HTTP method: #{method}"
    end

    http.request(request)
  end
end
