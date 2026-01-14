# frozen_string_literal: true

# Example worker that makes HTTP requests
class ExampleWorker
  include Sidekiq::AsyncHttp::Job

  sidekiq_options retry: 5

  sidekiq_retry_in { |count| 2 }

  success_callback do |response, method, url, timeout, delay|
    Sidekiq.logger.info("Request succeeded: #{method.upcase} #{url} - Status: #{response.status}")

    Sidekiq.redis do |conn|
      conn.incr("example_worker_success")
    end
  end

  error_callback do |error, method, url, timeout, delay|
    Sidekiq.logger.error("Request failed: #{method.upcase} #{url} - Error: #{error.message}")

    Sidekiq.redis do |conn|
      conn.incr("example_worker_error")
    end
  end

  class << self
    def status
      success = nil
      error = nil
      Sidekiq.redis do |conn|
        success = conn.get("example_worker_success").to_i
        error = conn.get("example_worker_error").to_i
      end
      {success: success, error: error}
    end

    def reset_counters
      Sidekiq.redis do |conn|
        conn.del("example_worker_success")
        conn.del("example_worker_error")
      end
    end
  end

  def perform(method, url, timeout, delay)
    async_request(method, url, timeout: timeout)
  end
end
