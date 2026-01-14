#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "irb"
require "sidekiq"
require_relative "../lib/sidekiq-async_http"

# Redis URL from environment or default to localhost
redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")

Sidekiq.configure_client do |config|
  config.redis = {url: redis_url}
end

# Load test workers
Dir.glob(File.join(__dir__, "workers/*.rb")).each do |file|
  require_relative file
end

puts "=" * 80
puts "Sidekiq::AsyncHttp Interactive Console"
puts "=" * 80
puts "Redis URL: #{redis_url}"
puts "Test workers loaded."
puts ""
puts "Available workers:"
puts "  - ExampleWorker.perform_async(url, method = 'GET')"
puts "  - PostWorker.perform_async(url, data_hash)"
puts "  - TimeoutWorker.perform_async(url, timeout = 5)"
puts ""
puts "Example:"
puts "  ExampleWorker.perform_async('https://httpbin.org/get')"
puts ""
puts "To process jobs, run 'rake test_app' in another terminal."
puts "Check queued jobs with: Sidekiq::Queue.new.size"
puts "=" * 80
puts ""

IRB.start
