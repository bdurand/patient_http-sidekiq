#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "sidekiq"
require "puma"
require_relative "../lib/sidekiq-async_http"

# Redis URL from environment or default to localhost
REDIS_URL = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
PORT = ENV.fetch("PORT", "9292").to_i

# Configure Sidekiq to use Valkey from docker-compose
Sidekiq.configure_server do |config|
  config.redis = {url: REDIS_URL}
  config.concurrency = 10
end

Sidekiq.configure_client do |config|
  config.redis = {url: REDIS_URL}
end

# Load test workers
require_relative "workers"

# Configure Sidekiq logging
Sidekiq.configure_server do |config|
  config.logger.level = Logger::INFO
end

# Start the Sidekiq::AsyncHttp processor
Sidekiq::AsyncHttp.configure do |config|
  config.max_connections = ENV.fetch("MAX_CONNECTIONS", "20").to_i
end

Sidekiq::AsyncHttp.start

puts "=" * 80
puts "Sidekiq::AsyncHttp Test Application"
puts "=" * 80
puts "Processor started with max_connections: #{Sidekiq::AsyncHttp.configuration.max_connections}"
puts "Redis URL: #{REDIS_URL}"
puts "Web UI: http://localhost:#{PORT}/sidekiq"
puts "=" * 80
puts ""

# Start Sidekiq server in background thread
sidekiq_thread = Thread.new do
  require "sidekiq/cli"
  cli = Sidekiq::CLI.instance
  cli.parse(["-r", "./test_app/workers.rb"])
  begin
    cli.run
  rescue Interrupt
    # Handle interrupt gracefully
  end
end

# Load the Rack app (Sidekiq Web UI)
require "rack"
app = Rack::Builder.parse_file(File.expand_path("config.ru", __dir__))

# Start Puma server
server = Puma::Server.new(app, nil, {min_threads: 0, max_threads: 24, log_writer: Puma::LogWriter.stdio})
server.add_tcp_listener("127.0.0.1", PORT)

begin
  server.run.join
rescue Interrupt
  puts "\nShutting down..."
ensure
  sidekiq_thread.kill if sidekiq_thread.alive?
end
