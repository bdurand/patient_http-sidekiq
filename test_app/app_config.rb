# frozen_string_literal: true

require "uri"

class AppConfig
  class << self
    def redis_url
      ENV.fetch("REDIS_URL", "redis://localhost:24470/1")
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

    # Named processor profiles in addition to the default one. The webhooks
    # profile is deliberately small so that filling it up is easy.
    def processor_profiles
      {
        llm: {
          max_connections: ENV.fetch("LLM_MAX_CONNECTIONS", "200").to_i,
          request_timeout: ENV.fetch("LLM_REQUEST_TIMEOUT", "120").to_f
        },
        webhooks: {
          max_connections: ENV.fetch("WEBHOOKS_MAX_CONNECTIONS", "25").to_i,
          request_timeout: ENV.fetch("WEBHOOKS_REQUEST_TIMEOUT", "10").to_f
        }
      }
    end

    # All processor names, including the default one.
    def processor_names
      [:default] + processor_profiles.keys
    end

    def redis_pool_size
      value = ENV["REDIS_POOL_SIZE"]
      value&.to_i
    end

    def stats_flush_interval
      ENV.fetch("STATS_FLUSH_INTERVAL", "5").to_f
    end

    def completion_threads
      ENV.fetch("COMPLETION_THREADS", "2").to_i
    end

    def sidekiq_concurrency
      ENV.fetch("SIDEKIQ_CONCURRENCY", "26").to_i
    end

    def port
      ENV.fetch("PORT", "9292").to_i
    end
  end
end
