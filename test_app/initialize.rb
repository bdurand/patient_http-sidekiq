# frozen_string_literal: true

require "time"
require "sidekiq"
require "sidekiq/encrypted_args"
require_relative "../lib/patient_http-sidekiq"

require_relative "app_config"

Sidekiq::EncryptedArgs.configure!(secret: "A_VERY_SECRET_KEY_FOR_TESTING_PURPOSES_ONLY!")

# Configure Sidekiq to use Valkey from docker-compose
Sidekiq.configure_server do |config|
  config.redis = {url: AppConfig.redis_url}
end

Sidekiq.configure_client do |config|
  config.redis = {url: AppConfig.redis_url}
end

# Configure PatientHttp::Sidekiq processor
PatientHttp::Sidekiq.configure do |config|
  config.max_connections = AppConfig.max_connections
  config.proxy_url = ENV["HTTP_PROXY"]
  config.register_payload_store(:files, adapter: :file, directory: File.join(__dir__, "tmp/payloads"))
  config.payload_store_threshold = 1024
end

PatientHttp::Sidekiq.after_completion do |response|
  Sidekiq.logger.info("Async HTTP Continuation: #{response.status} #{response.http_method.to_s.upcase} #{response.url}")
end

PatientHttp::Sidekiq.after_error do |error|
  Sidekiq.logger.error("Async HTTP Error: #{error.error_class.name} #{error.message} on #{error.http_method.to_s.upcase} #{error.url}")
end

Dir.glob(File.join(__dir__, "lib/*.rb")).each do |file|
  require_relative file
end
