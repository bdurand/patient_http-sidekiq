# frozen_string_literal: true

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

require_relative "../lib/sidekiq-async_http"

# Disable all real HTTP connections
WebMock.disable_net_connect!

# Use fake mode for Sidekiq during tests
Sidekiq::Testing.fake!

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed

  # Include Async::RSpec::Reactor for async tests
  config.include Async::RSpec::Reactor

  # Reset SidekiqAsyncHttp state between tests
  config.before do
    # Clear Sidekiq queues
    Sidekiq::Worker.clear_all

    # Reset Sidekiq::AsyncHttp if it has been initialized
    if defined?(Sidekiq::AsyncHttp) && Sidekiq::AsyncHttp.instance_variable_get(:@processor)
      Sidekiq::AsyncHttp.processor&.shutdown
    end
  end

  config.after do
    # Ensure processor is stopped after each test
    if defined?(Sidekiq::AsyncHttp) && Sidekiq::AsyncHttp.instance_variable_get(:@processor)
      Sidekiq::AsyncHttp.processor&.shutdown
    end
  end
end
