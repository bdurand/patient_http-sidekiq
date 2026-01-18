# frozen_string_literal: true

require "uri"

class AppConfig
  class << self
    def redis_url
      ENV.fetch("REDIS_URL", "redis://localhost:24455/1")
    end

    def redacted_redis_url
      uri = URI.parse(redis_url)
      if uri.password
        uri.password = "REDACTED"
      end
      if uri.user
        uri.user = "REDACTED"
      end
      uri.to_s
    rescue URI::InvalidURIError
      "invalid_url"
    end

    def max_connections
      ENV.fetch("MAX_CONNECTIONS", "500").to_i
    end

    def sidekiq_concurrency
      ENV.fetch("SIDEKIQ_CONCURRENCY", "26").to_i
    end

    def port
      ENV.fetch("PORT", "9292").to_i
    end
  end
end
