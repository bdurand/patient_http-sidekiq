# frozen_string_literal: true

require "sidekiq"
require "sidekiq/throttled"
require "sidekiq/encrypted_args"
require_relative "../lib/sidekiq-async_http"

require_relative "app_config"

Sidekiq::EncryptedArgs.configure!(secret: "A_VERY_SECRET_KEY_FOR_TESTING_PURPOSES_ONLY!")

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
  Sidekiq.logger.info("Async HTTP Completed Continuation: #{response.status} #{response.method.to_s.upcase} #{response.url}")
end

Sidekiq::AsyncHttp.after_error do |error|
  Sidekiq.logger.error("Async HTTP Error Continuation: #{error.class_name} #{error.message} on #{error.method.to_s.upcase} #{error.url}")
end

# Load test workers
Dir.glob(File.join(__dir__, "workers/*.rb")).each do |file|
  require_relative file
end
