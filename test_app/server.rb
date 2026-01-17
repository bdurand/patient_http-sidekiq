#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "async"
require "async/http/endpoint"
require "async/http/server"
require "protocol/rack"

require_relative "initialize"

# Load the Rack app (which configures everything)
require "rack"
rack_app, _ = Rack::Builder.parse_file(File.expand_path("config.ru", __dir__))

# Wrap Rack app for async HTTP server
app = Protocol::Rack::Adapter.new(rack_app)

puts "=" * 80
puts "Sidekiq::AsyncHttp Test Application (Async HTTP Server)"
puts "=" * 80
puts "Processor max_connections: #{Sidekiq::AsyncHttp.configuration.max_connections}"
puts "Redis URL: #{AppConfig.redacted_redis_url}"
puts "Web UI: http://localhost:#{AppConfig.port}/"
puts "=" * 80
puts ""

# Embed Sidekiq using configure_embed
sidekiq = Sidekiq.configure_embed do |config|
  config.logger.level = Logger::INFO
  config.concurrency = AppConfig.sidekiq_concurrency
end

# Start Sidekiq in a background thread
sidekiq_thread = Thread.new do
  sidekiq.run
end

# Create endpoint
endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{AppConfig.port}")
# Shutdown handling
shutdown_requested = false

trap("INT") do
  shutdown_requested = true
end

trap("TERM") do
  shutdown_requested = true
end

# Start async HTTP server
Async do |task|
  # Start the server
  server = Async::HTTP::Server.new(app, endpoint)
  server_task = task.async do
    server.run
  end

  # Monitor for shutdown
  task.async do
    until shutdown_requested
      sleep 0.1
    end

    puts "\nShutting down..."
    sidekiq.stop
    sidekiq_thread.join(10)
    server_task.stop
  end
end
