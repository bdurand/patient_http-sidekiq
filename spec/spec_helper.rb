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
require "mock_redis"

require_relative "../lib/sidekiq-async_http"

# Disable all real HTTP connections except localhost (for test server)
WebMock.disable_net_connect!(allow_localhost: true)

# Use fake mode for Sidekiq during tests
Sidekiq::Testing.fake!

# Disable strict args checking for tests since processor uses symbol-keyed hashes
Sidekiq.strict_args!(false)

# Disable Sidekiq logging during tests
Sidekiq.logger.level = Logger::FATAL

Dir.glob(File.join(__dir__, "support", "**", "*.rb")).sort.each do |file|
  require file
end

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

  if config.files_to_run.length > 1
    config.profile_examples = 5
  end

  if config.files_to_run.any? { |f| f.include?("/integration/") }
    config.before(:suite) do
      test_web_server.start
    end
  end

  # Include Async::RSpec::Reactor for async tests
  config.include Async::RSpec::Reactor

  # Setup MockRedis for testing
  config.before(:suite) do
    $mock_redis = MockRedis.new # rubocop:disable Style/GlobalVars
  end

  config.before do |example|
    $mock_redis.flushdb # rubocop:disable Style/GlobalVars
    allow(Sidekiq).to receive(:redis).and_yield($mock_redis) # rubocop:disable Style/GlobalVars
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
  end
end
