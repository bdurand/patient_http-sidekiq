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

require_relative "../lib/sidekiq-async_http"

# Disable all real HTTP connections
WebMock.disable_net_connect!

# Use fake mode for Sidekiq during tests
Sidekiq::Testing.fake!

# Disable strict args checking for tests since processor uses symbol-keyed hashes
Sidekiq.strict_args!(false)

# Disable Sidekiq logging during tests
Sidekiq.logger.level = Logger::FATAL

module TestHelper
  class Worker
    include Sidekiq::Job

    def perform(*args)
    end
  end

  class SuccessWorker
    include Sidekiq::Job

    def perform(*args)
    end
  end

  class ErrorWorker
    include Sidekiq::Job

    def perform(*args)
    end
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed

  # Include Async::RSpec::Reactor for async tests
  config.include Async::RSpec::Reactor

  config.before do
    Sidekiq::Worker.clear_all
  end

  config.after do
    Sidekiq::AsyncHttp.processor.shutdown if Sidekiq::AsyncHttp.running?
  end

  config.around do |example|
    start_time = Time.now
    example.run
    if Time.now - start_time > 1
      puts "WARNING: Example #{example.full_description} took more than 1 second to run."
    end
  end
end
