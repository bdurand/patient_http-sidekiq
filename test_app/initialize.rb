# frozen_string_literal: true

require "time"
require "sidekiq"
require "sidekiq/throttled"
require "sidekiq/encrypted_args"
require "active_job"
require "faraday-sidekiq_async_http"
require_relative "../lib/sidekiq-async_http"

require_relative "app_config"

Sidekiq::EncryptedArgs.configure!(secret: "A_VERY_SECRET_KEY_FOR_TESTING_PURPOSES_ONLY!")
Sidekiq::AsyncHttp.append_middleware

# Configure ActiveJob to use Sidekiq
ActiveJob::Base.queue_adapter = :sidekiq
Sidekiq::ActiveJob::Wrapper.include(Sidekiq::Throttled::Job)
Sidekiq::ActiveJob::Wrapper.sidekiq_throttle concurrency: {limit: 25}

# Configure Sidekiq to use Valkey from docker-compose
Sidekiq.configure_server do |config|
  config.redis = {url: AppConfig.redis_url}
end

Sidekiq.configure_client do |config|
  config.redis = {url: AppConfig.redis_url}
end

# Configure Sidekiq::AsyncHttp processor
Sidekiq::AsyncHttp.configure do |config|
  config.max_connections = AppConfig.max_connections
end

Sidekiq::AsyncHttp.after_completion do |response|
  Sidekiq.logger.info("Async HTTP Continuation: #{response.status} #{response.http_method.to_s.upcase} #{response.url}")
end

Sidekiq::AsyncHttp.after_error do |error|
  Sidekiq.logger.error("Async HTTP Error: #{error.error_class.name} #{error.message} on #{error.http_method.to_s.upcase} #{error.url}")
end

# Load test workers
Dir.glob(File.join(__dir__, "workers/*.rb")).each do |file|
  require_relative file
end
