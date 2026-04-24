# frozen_string_literal: true

require "time"
require "sidekiq"
require "openssl"
require_relative "../lib/patient_http-sidekiq"

require_relative "app_config"

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
  # Test encryption using custom encryption/decryption callables.
  # This uses AES-256-GCM directly instead of the encryption_key shortcut.
  encryption_secret = "A_VERY_SECRET_KEY_FOR_TESTING_PURPOSES_ONLY!"
  encryption_key = OpenSSL::Digest::SHA256.digest(encryption_secret)

  config.encryption ->(data) {
    cipher = OpenSSL::Cipher.new("aes-256-gcm")
    cipher.encrypt
    iv = cipher.random_iv
    cipher.key = encryption_key
    encrypted = cipher.update(data) + cipher.final
    tag = cipher.auth_tag
    [iv + tag + encrypted].pack("m0")
  }

  config.decryption ->(data) {
    raw = data.unpack1("m0")
    iv = raw[0, 12]
    tag = raw[12, 16]
    encrypted = raw[28..]
    cipher = OpenSSL::Cipher.new("aes-256-gcm")
    cipher.decrypt
    cipher.iv = iv
    cipher.key = encryption_key
    cipher.auth_tag = tag
    cipher.update(encrypted) + cipher.final
  }
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
