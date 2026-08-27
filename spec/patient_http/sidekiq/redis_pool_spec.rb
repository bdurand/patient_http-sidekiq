# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::RedisPool do
  let(:config) { PatientHttp::Sidekiq::Configuration.new }
  let(:redis_pool) { described_class.new(config) }

  after do
    redis_pool.shutdown
  end

  describe "#pool" do
    it "builds a ConnectionPool from the application's Sidekiq Redis configuration" do
      redis_pool.with { |redis| redis.call("SET", "redis_pool_spec_key", "value") }

      value = ::Sidekiq.redis { |redis| redis.get("redis_pool_spec_key") }
      expect(value).to eq("value")
    end

    it "memoizes the pool" do
      expect(redis_pool.pool).to be(redis_pool.pool)
    end

    it "sizes the pool from completion_threads with a floor" do
      expect(redis_pool.pool.size).to eq(10)

      big_config = PatientHttp::Sidekiq::Configuration.new(completion_threads: 12)
      big_pool = described_class.new(big_config)
      begin
        expect(big_pool.pool.size).to eq(15)
      ensure
        big_pool.shutdown
      end
    end

    it "uses an explicit redis_pool_size when configured" do
      sized_config = PatientHttp::Sidekiq::Configuration.new(redis_pool_size: 3)
      sized_pool = described_class.new(sized_config)
      begin
        expect(sized_pool.pool.size).to eq(3)
      ensure
        sized_pool.shutdown
      end
    end

    it "rebuilds the pool when the process id changes" do
      original = redis_pool.pool
      redis_pool.instance_variable_set(:@pid, -1)

      expect(redis_pool.pool).not_to be(original)
    end
  end

  describe "#with" do
    it "applies the configured checkout timeout" do
      tiny_config = PatientHttp::Sidekiq::Configuration.new(redis_pool_size: 1, redis_pool_timeout: 0.1)
      tiny_pool = described_class.new(tiny_config)

      begin
        checked_out = Concurrent::CountDownLatch.new(1)
        release = Concurrent::CountDownLatch.new(1)
        holder = Thread.new do
          tiny_pool.with do |_redis|
            checked_out.count_down
            release.wait(5)
          end
        end

        expect(checked_out.wait(2)).to be(true)
        expect { tiny_pool.with { |redis| redis.call("PING") } }.to raise_error(ConnectionPool::TimeoutError)

        release.count_down
        holder.join
      ensure
        tiny_pool.shutdown
      end
    end
  end

  describe "#shutdown" do
    it "drops the pool and allows a fresh one to be created" do
      original = redis_pool.pool
      redis_pool.shutdown

      expect(redis_pool.pool).not_to be(original)
      expect(redis_pool.with { |redis| redis.call("PING") }).to eq("PONG")
    end
  end
end
