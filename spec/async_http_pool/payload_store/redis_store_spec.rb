# frozen_string_literal: true

require "spec_helper"

RSpec.describe AsyncHttpPool::PayloadStore::RedisStore do
  # Helper to get a Redis connection for tests
  def with_redis(&block)
    Sidekiq.redis(&block)
  end

  # Create stores using Sidekiq.redis block pattern
  def create_store(**options)
    Sidekiq.redis do |redis|
      described_class.new(redis: redis, **options)
    end
  end

  describe ".register" do
    it "is registered as :redis adapter" do
      expect(AsyncHttpPool::PayloadStore::Base.lookup(:redis)).to eq(described_class)
    end
  end

  describe "#initialize" do
    it "raises ArgumentError when redis client not provided" do
      expect { described_class.new(redis: nil) }.to raise_error(ArgumentError, "redis client is required")
    end

    it "accepts redis client" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        expect(store).to be_a(described_class)
      end
    end

    it "accepts custom TTL" do
      with_redis do |redis|
        store = described_class.new(redis: redis, ttl: 3600)
        expect(store.ttl).to eq(3600)
      end
    end

    it "defaults TTL to nil" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        expect(store.ttl).to be_nil
      end
    end

    it "accepts custom key_prefix" do
      with_redis do |redis|
        store = described_class.new(redis: redis, key_prefix: "custom:")
        expect(store.key_prefix).to eq("custom:")
      end
    end

    it "defaults key_prefix to async_http_pool:payloads:" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        expect(store.key_prefix).to eq("async_http_pool:payloads:")
      end
    end
  end

  describe "#store" do
    it "stores data as JSON in Redis" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        data = {"status" => 200, "body" => "test"}
        key = store.store("test-key", data)

        expect(key).to eq("test-key")
        stored = redis.get("async_http_pool:payloads:test-key")
        expect(stored).to eq(JSON.generate(data))
      end
    end

    it "uses custom key_prefix" do
      with_redis do |redis|
        store = described_class.new(redis: redis, key_prefix: "test:payloads:")
        data = {"status" => 200}
        store.store("test-key", data)

        expect(redis.get("test:payloads:test-key")).to eq(JSON.generate(data))
      end
    end

    it "overwrites existing data" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        store.store("test-key", {"version" => 1})
        store.store("test-key", {"version" => 2})

        fetched = store.fetch("test-key")
        expect(fetched["version"]).to eq(2)
      end
    end

    it "sets TTL when configured" do
      with_redis do |redis|
        store = described_class.new(redis: redis, ttl: 60)
        store.store("test-key", {"data" => "value"})

        ttl = redis.ttl("async_http_pool:payloads:test-key")
        expect(ttl).to be > 0
        expect(ttl).to be <= 60
      end
    end

    it "does not set TTL when not configured" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        store.store("test-key", {"data" => "value"})

        ttl = redis.ttl("async_http_pool:payloads:test-key")
        expect(ttl).to eq(-1)
      end
    end
  end

  describe "#fetch" do
    it "retrieves stored data" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        data = {"status" => 200, "headers" => {"content-type" => "application/json"}}
        store.store("test-key", data)

        fetched = store.fetch("test-key")
        expect(fetched).to eq(data)
      end
    end

    it "returns nil for non-existent keys" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        expect(store.fetch("nonexistent")).to be_nil
      end
    end
  end

  describe "#delete" do
    it "removes stored data" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        store.store("test-key", {"data" => "value"})
        expect(store.fetch("test-key")).not_to be_nil

        result = store.delete("test-key")
        expect(result).to be true
        expect(store.fetch("test-key")).to be_nil
      end
    end

    it "is idempotent for non-existent keys" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        expect(store.delete("nonexistent")).to be true
        expect(store.delete("nonexistent")).to be true
      end
    end
  end

  describe "#exists?" do
    it "returns true for existing keys" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        store.store("test-key", {"data" => "value"})
        expect(store.exists?("test-key")).to be true
      end
    end

    it "returns false for non-existent keys" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        expect(store.exists?("nonexistent")).to be false
      end
    end
  end

  describe "thread safety" do
    it "handles concurrent access safely" do
      threads = 10.times.map do |i|
        Thread.new do
          # Each thread gets its own Redis connection from the pool
          Sidekiq.redis do |redis|
            store = described_class.new(redis: redis)
            key = "thread-#{i}"
            data = {"thread" => i, "data" => "x" * 1000}

            store.store(key, data)
            fetched = store.fetch(key)
            expect(fetched["thread"]).to eq(i)
            store.delete(key)
          end
        end
      end

      threads.each(&:join)
    end
  end

  describe "round trip" do
    it "stores and retrieves complex data" do
      with_redis do |redis|
        store = described_class.new(redis: redis)
        data = {
          "status" => 200,
          "headers" => {"content-type" => "application/json", "x-custom" => "value"},
          "body" => {"encoding" => "text", "value" => "large body " * 1000},
          "duration" => 0.5,
          "redirects" => ["http://old.url", "http://new.url"]
        }

        key = store.generate_key
        store.store(key, data)
        fetched = store.fetch(key)

        expect(fetched).to eq(data)
      end
    end
  end

  describe "TTL expiration" do
    it "keys expire after TTL" do
      with_redis do |redis|
        store = described_class.new(redis: redis, ttl: 1)
        store.store("expiring-key", {"data" => "value"})

        expect(store.exists?("expiring-key")).to be true

        sleep(1.5)

        expect(store.exists?("expiring-key")).to be false
        expect(store.fetch("expiring-key")).to be_nil
      end
    end
  end
end
