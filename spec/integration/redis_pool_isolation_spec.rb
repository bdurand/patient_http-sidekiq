# frozen_string_literal: true

require "spec_helper"
require "support/test_web_server"

# Regression test for the completion-loss scenario: many concurrent
# completions must all deliver their callback jobs even when the gem's Redis
# pool is small, and the crash-recovery registry must drain to zero. Before
# the dedicated pool and the delivery-failure fix, checkout timeouts on
# Sidekiq's internal pool silently dropped responses and deleted their
# recovery records.
RSpec.describe "Redis pool isolation under load", :integration do
  around do |example|
    original_testing_mode = Sidekiq::Testing.instance_variable_get(:@test_mode) || :fake
    Sidekiq::Testing.disable!
    begin
      example.run
    ensure
      if original_testing_mode == :inline
        Sidekiq::Testing.inline!
      elsif original_testing_mode == :disable
        Sidekiq::Testing.disable!
      else
        Sidekiq::Testing.fake!
      end
    end
  end

  after do
    PatientHttp::Sidekiq.reset!
    PatientHttp::Sidekiq.reset_configuration!
  end

  def wait_until(timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      return true if yield

      sleep(0.05)
    end
    false
  end

  def enqueued_jobs(queue = "default")
    payloads = ::Sidekiq.redis { |redis| redis.lrange("queue:#{queue}", 0, -1) }
    payloads.map { |json| JSON.parse(json) }
  end

  it "delivers every callback with a small dedicated pool and drains the registry" do
    request_count = 200

    PatientHttp::Sidekiq.configure do |config|
      config.max_connections = request_count
      config.redis_pool_size = 4
      config.completion_threads = 4
      config.stats_flush_interval = 1
    end
    PatientHttp::Sidekiq.start

    request_ids = Array.new(request_count) do
      request = PatientHttp::Request.new(:get, "#{test_web_server.base_url}/test/200")
      PatientHttp::Sidekiq.execute(request, callback: TestCallback)
    end

    expect(wait_until { enqueued_jobs.size == request_count }).to be(true),
      "expected #{request_count} callback jobs, got #{enqueued_jobs.size}"

    jobs = enqueued_jobs
    expect(jobs.map { |job| job["class"] }.uniq).to eq(["PatientHttp::Sidekiq::CallbackWorker"])

    # Every request produced exactly one callback job.
    expect(request_ids.uniq.size).to eq(request_count)

    # The crash-recovery registry drains to zero: nothing was lost and nothing
    # was leaked for the orphan collector to re-enqueue later.
    expect(wait_until { PatientHttp::Sidekiq::TaskMonitor.inflight_count == 0 }).to be(true)

    # The aggregated stats add up after a flush.
    totals = PatientHttp::Sidekiq.stats.get_totals
    expect(totals["requests"]).to eq(request_count)
  end
end
