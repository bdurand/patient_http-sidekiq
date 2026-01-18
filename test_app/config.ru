# frozen_string_literal: true

require "bundler/setup"
require "rack/session"
require_relative "../lib/sidekiq-async_http"
require_relative "../lib/sidekiq/async_http/web_ui"

Dir.glob(File.join(__dir__, "actions/*.rb")).each do |file|
  require file
end

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
  run IndexAction.new
end

# Handle job submission
map "/run_jobs" do
  run RunJobsAction.new
end

map "/test" do
  run TestAction.new
end

map "/status" do
  run StatusAction.new
end

map "/favicon.ico" do
  run lambda { |env| [204, {}, []] }
end
