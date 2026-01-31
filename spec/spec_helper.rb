# frozen_string_literal: true

# Suppress experimental feature warnings (IO::Buffer used by async gems)
Warning[:experimental] = false

# SimpleCov must be started before requiring the lib
require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  enable_coverage :branch
end

require "bundler/setup"

require "webmock/rspec"
require "async/rspec"
require "sidekiq/testing"
require "console"

# Suppress Async task warnings (like EPIPE errors from early connection closes)
# These are expected in tests that intentionally close connections early
Console.logger.level = Logger::FATAL

require_relative "../lib/sidekiq-async_http"

# Configure Redis URL for tests - use Valkey container on port 24455, database 0
# Can be overridden with REDIS_URL environment variable
# Using 127.0.0.1 instead of localhost to avoid macOS local network permission issues
ENV["REDIS_URL"] ||= "redis://127.0.0.1:24455/0"

# Disable all real HTTP connections except localhost (for test server)
WebMock.disable_net_connect!(allow_localhost: true)

# Use fake mode for Sidekiq during tests
Sidekiq::Testing.fake!

Sidekiq.strict_args!(true)

# Disable Sidekiq logging during tests
Sidekiq.logger.level = Logger::ERROR

Dir.glob(File.join(__dir__, "support", "**", "*.rb")).sort.each do |file|
  require file
end

# Set up Sidekiq middlewares for tests
Sidekiq::AsyncHttp.append_middleware

$test_web_server = nil # rubocop:disable Style/GlobalVars
def test_web_server
  $test_web_server ||= TestWebServer.new # rubocop:disable Style/GlobalVars
end

Sidekiq::AsyncHttp.testing = true

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one? || ENV["RSPEC_FORMATTER"] == "doc"
  config.order = :random
  Kernel.srand config.seed

  config.profile_examples = 5 if config.files_to_run.length > 1

  if config.files_to_run.any? { |f| f.include?("/integration/") }
    config.before(:suite) do
      test_web_server.start
    end
  end

  # Include Async::RSpec::Reactor for async tests
  config.include Async::RSpec::Reactor

  # Flush Redis database before test suite runs
  config.before(:suite) do
    # Retry connection in case Redis is starting up
    retries = 3
    begin
      Sidekiq.redis(&:flushdb)
    rescue RedisClient::CannotConnectError
      retries -= 1
      raise unless retries > 0

      sleep(0.5)
      retry
    end
  end

  # Flush Redis database after each test
  config.before do |_example|
    Sidekiq.redis(&:flushdb)
    Sidekiq::Worker.clear_all
  end

  config.after do
    Sidekiq::AsyncHttp.reset! if Sidekiq::AsyncHttp.running?
  end

  config.before(:each, :integration) do
    test_web_server.start.ready?
  end

  config.around(:each, :disable_testing_mode) do |example|
    Sidekiq::AsyncHttp.testing = false
    example.run
  ensure
    Sidekiq::AsyncHttp.testing = true
  end

  config.after(:suite) do
    test_web_server.stop
    Sidekiq::AsyncHttp.stop if Sidekiq::AsyncHttp.running?
  end
end
