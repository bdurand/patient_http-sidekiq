# frozen_string_literal: true

require "bundler/setup"
require "sidekiq"
require "sidekiq/web"
require "securerandom"
require "rack/session"
require_relative "../lib/sidekiq-async_http"

# Load the Web UI extension after Sidekiq::Web is available
Sidekiq::AsyncHttp.load_web_ui

require_relative "../lib/sidekiq/async_http/sidekiq"

# Redis URL from environment or default to localhost
REDIS_URL = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")

# Configure Sidekiq to use Valkey from docker-compose
Sidekiq.configure_server do |config|
  config.redis = {url: REDIS_URL}
end

Sidekiq.configure_client do |config|
  config.redis = {url: REDIS_URL}
end

# Load test workers
require_relative "workers"

# Generate or load session secret for Sidekiq::Web
session_key_file = File.expand_path(".session.key", __dir__)
unless File.exist?(session_key_file)
  File.write(session_key_file, SecureRandom.hex(32))
end
session_secret = File.read(session_key_file)

# Mount Sidekiq Web UI under /sidekiq with session middleware
map "/sidekiq" do
  use Rack::Session::Cookie, secret: session_secret, same_site: true, max_age: 86400
  run Sidekiq::Web
end

# Root path with form
map "/" do
  run lambda { |env|
    [
      200,
      {"Content-Type" => "text/html"},
      [File.read(File.expand_path("index.html", __dir__))]
    ]
  }
end

# Handle job submission
map "/run_jobs" do
  run lambda { |env|
    request = Rack::Request.new(env)
    return method_not_allowed_response unless request.post?

    count = request.params["count"].to_i.clamp(1, 1000)
    delay = request.params["delay"].to_f
    timeout = request.params["timeout"].to_f
    randomize = request.params["randomize"] == "true"

    # Build the test URL for this application
    port = ENV.fetch("PORT", "9292")
    test_url = "http://localhost:#{port}/test?delay=#{delay}"
    test_url += "&randomize=true" if randomize

    count.times do
      ExampleWorker.perform_async("GET", test_url, timeout, delay)
    end
    [204, {}, []]
  }
end

map "/test" do
  run lambda { |env|
    request = Rack::Request.new(env)
    delay = request.params["delay"]&.to_f
    randomize = request.params["randomize"] == "true"

    [
      200,
      {"Content-Type" => "text/plain; charset=utf-8"},
      TestAppStreamingBody.new(delay, randomize)
    ]
  }
end

map "/status" do
  run lambda { |env|
    sidekiq_stats = Sidekiq::Stats.new
    status = ExampleWorker.status.merge(
      enqueued: sidekiq_stats.enqueued,
      processed: sidekiq_stats.processed,
      failed: sidekiq_stats.failed
    )

    [
      200,
      {"Content-Type" => "application/json; charset=utf-8"},
      [JSON.generate(status)]
    ]
  }
end

map "/favicon.ico" do
  run lambda { |env|
    [204, {}, []]
  }
end

def method_not_allowed_response
  [405, {"Content-Type" => "text/plain"}, ["Method Not Allowed"]]
end

class TestAppStreamingBody
  def initialize(delay, randomize = false)
    @delay = delay
    @randomize = randomize
  end

  def each
    yield "start"
    yield "..."
    if @delay > 0
      actual_delay = @randomize ? rand((@delay / 2)..(@delay * 1.5)) : @delay
      sleep(actual_delay) if actual_delay > 0
    end
    yield "end"
  end
end
