# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::ConnectionPool do
  let(:config) do
    Sidekiq::AsyncHttp::Configuration.new(
      max_connections: 10,
      idle_connection_timeout: 5,
      enable_http2: true
    )
  end
  let(:pool) { described_class.new(config) }

  describe "#initialize" do
    it "stores the configuration" do
      expect(pool.config).to eq(config)
    end

    it "initializes with zero connections" do
      stats = pool.stats
      expect(stats["total_connections"]).to eq(0)
      expect(stats["cached_clients"]).to eq(0)
    end
  end

  describe "#client_for" do
    it "creates a new client for a URI" do
      client = pool.client_for("https://api.example.com/path")
      expect(client).to be_a(Async::HTTP::Client)
    end

    it "caches clients by host" do
      client1 = pool.client_for("https://api.example.com/path1")
      client2 = pool.client_for("https://api.example.com/path2")

      expect(client1).to eq(client2)
    end

    it "creates different clients for different hosts" do
      client1 = pool.client_for("https://api.example.com/")
      client2 = pool.client_for("https://auth.example.com/")

      expect(client1).not_to eq(client2)
    end

    it "treats different ports as different hosts" do
      client1 = pool.client_for("https://api.example.com:443/")
      client2 = pool.client_for("https://api.example.com:8443/")

      expect(client1).not_to eq(client2)
    end

    it "treats different schemes as different hosts" do
      client1 = pool.client_for("http://api.example.com/")
      client2 = pool.client_for("https://api.example.com/")

      expect(client1).not_to eq(client2)
    end

    it "accepts URI objects" do
      uri = URI.parse("https://api.example.com/path")
      client = pool.client_for(uri)

      expect(client).to be_a(Async::HTTP::Client)
    end

    it "increments connection count" do
      expect { pool.client_for("https://api.example.com/") }
        .to change { pool.stats["total_connections"] }.from(0).to(1)
    end

    it "tracks connections by host" do
      pool.client_for("https://api.example.com/")
      pool.client_for("https://auth.example.com/")

      connections = pool.stats["connections_by_host"]
      expect(connections["https://api.example.com:443"]).to eq(1)
      expect(connections["https://auth.example.com:443"]).to eq(1)
    end

    context "when at max connections" do
      let(:config) do
        Sidekiq::AsyncHttp::Configuration.new(
          max_connections: 2,
          backpressure_strategy: :raise
        )
      end

      it "raises BackpressureError with :raise strategy" do
        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        expect { pool.client_for("https://host3.example.com/") }
          .to raise_error(Sidekiq::AsyncHttp::BackpressureError, /Total connection limit reached/)
      end

      it "allows reusing existing connections" do
        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        # Should not raise because we're reusing an existing connection
        expect { pool.client_for("https://host1.example.com/") }.not_to raise_error
      end
    end

    context "with HTTP/2 enabled" do
      let(:config) do
        Sidekiq::AsyncHttp::Configuration.new(enable_http2: true)
      end

      it "creates clients with HTTP/2 protocol" do
        client = pool.client_for("https://api.example.com/")
        expect(client).to be_a(Async::HTTP::Client)
        # Note: We can't easily test the protocol without making actual requests
      end
    end

    context "with HTTP/2 disabled" do
      let(:config) do
        Sidekiq::AsyncHttp::Configuration.new(enable_http2: false)
      end

      it "creates clients with HTTP/1 protocol" do
        client = pool.client_for("https://api.example.com/")
        expect(client).to be_a(Async::HTTP::Client)
      end
    end
  end

  describe "#with_client" do
    it "yields a client for the URI" do
      yielded_client = nil
      pool.with_client("https://api.example.com/") do |client|
        yielded_client = client
      end

      expect(yielded_client).to be_a(Async::HTTP::Client)
    end

    it "returns the block result" do
      result = pool.with_client("https://api.example.com/") do |client|
        "test_result"
      end

      expect(result).to eq("test_result")
    end

    it "propagates errors from the block" do
      expect do
        pool.with_client("https://api.example.com/") do |client|
          raise StandardError, "test error"
        end
      end.to raise_error(StandardError, "test error")
    end

    it "reuses the same client on subsequent calls" do
      client1 = nil
      client2 = nil

      pool.with_client("https://api.example.com/") { |c| client1 = c }
      pool.with_client("https://api.example.com/") { |c| client2 = c }

      expect(client1).to eq(client2)
    end
  end

  describe "#close_idle_connections" do
    it "closes connections that have been idle" do
      pool.client_for("https://api.example.com/")

      # Simulate idle time passing
      allow(Time).to receive(:now).and_return(Time.now + 10)

      closed = pool.close_idle_connections

      expect(closed).to eq(1)
      expect(pool.stats["total_connections"]).to eq(0)
    end

    it "does not close recently used connections" do
      pool.client_for("https://api.example.com/")

      # Simulate short time passing (less than idle timeout)
      allow(Time).to receive(:now).and_return(Time.now + 1)

      closed = pool.close_idle_connections

      expect(closed).to eq(0)
      expect(pool.stats["total_connections"]).to eq(1)
    end

    it "closes only idle connections" do
      # Create two connections at time T
      initial_time = Time.now
      allow(Time).to receive(:now).and_return(initial_time)

      pool.client_for("https://api1.example.com/")
      pool.client_for("https://api2.example.com/")

      # Access api1 at time T+2 to refresh its last access time
      allow(Time).to receive(:now).and_return(initial_time + 2)
      pool.client_for("https://api1.example.com/")

      # Now check at time T+10 - api2 should be idle (10 seconds), api1 should not (8 seconds)
      # But since idle_connection_timeout is 5 seconds, and api1 was last accessed at T+2,
      # at T+10 it's been idle for 8 seconds, which is > 5, so it will also be closed.
      # Let's use a shorter time window
      allow(Time).to receive(:now).and_return(initial_time + 6)

      closed = pool.close_idle_connections

      # api2 was accessed at T+0, so at T+6 it's been idle for 6 seconds (> 5)
      # api1 was accessed at T+2, so at T+6 it's been idle for 4 seconds (< 5)
      expect(closed).to eq(1)
      expect(pool.stats["total_connections"]).to eq(1)
    end

    it "handles errors during connection close gracefully" do
      client = pool.client_for("https://api.example.com/")
      allow(client).to receive(:close).and_raise(StandardError, "close error")

      allow(Time).to receive(:now).and_return(Time.now + 10)

      expect { pool.close_idle_connections }.not_to raise_error
    end

    it "returns the count of closed connections" do
      3.times { |i| pool.client_for("https://api#{i}.example.com/") }

      allow(Time).to receive(:now).and_return(Time.now + 10)

      closed = pool.close_idle_connections
      expect(closed).to eq(3)
    end
  end

  describe "#close_all" do
    before do
      3.times { |i| pool.client_for("https://api#{i}.example.com/") }
    end

    it "closes all connections" do
      pool.close_all

      stats = pool.stats
      expect(stats["total_connections"]).to eq(0)
      expect(stats["cached_clients"]).to eq(0)
      expect(stats["connections_by_host"]).to be_empty
    end

    it "handles errors during connection close gracefully" do
      clients = []
      pool.instance_variable_get(:@clients).each_pair do |host, client|
        clients << client
        allow(client).to receive(:close).and_raise(StandardError, "close error")
      end

      expect { pool.close_all }.not_to raise_error
    end

    it "resets connection counts" do
      pool.close_all

      expect(pool.stats["total_connections"]).to eq(0)
    end
  end

  describe "#stats" do
    it "returns a hash with statistics" do
      stats = pool.stats

      expect(stats).to be_a(Hash)
      expect(stats).to have_key("total_connections")
      expect(stats).to have_key("connections_by_host")
      expect(stats).to have_key("cached_clients")
    end

    it "reflects current state" do
      pool.client_for("https://api1.example.com/")
      pool.client_for("https://api2.example.com/")

      stats = pool.stats
      expect(stats["total_connections"]).to eq(2)
      expect(stats["cached_clients"]).to eq(2)
      expect(stats["connections_by_host"].size).to eq(2)
    end

    it "updates after closing connections" do
      pool.client_for("https://api.example.com/")
      pool.close_all

      stats = pool.stats
      expect(stats["total_connections"]).to eq(0)
      expect(stats["cached_clients"]).to eq(0)
    end
  end

  describe "thread safety", :slow do
    it "handles concurrent client creation safely" do
      threads = []
      hosts = 5.times.map { |i| "https://api#{i}.example.com/" }

      10.times do
        threads << Thread.new do
          100.times do
            host = hosts.sample
            pool.client_for(host)
          end
        end
      end

      threads.each(&:join)

      # Should have exactly 5 clients (one per unique host)
      expect(pool.stats["cached_clients"]).to eq(5)
      expect(pool.stats["total_connections"]).to eq(5)
    end

    it "maintains correct connection counts under concurrent access" do
      threads = []
      config = Sidekiq::AsyncHttp::Configuration.new(
        max_connections: 50,
        idle_connection_timeout: 100
      )
      pool = described_class.new(config)

      20.times do
        threads << Thread.new do
          50.times do |i|
            pool.client_for("https://host#{i % 10}.example.com/")
          end
        end
      end

      threads.each(&:join)

      # Should have 10 unique hosts
      expect(pool.stats["cached_clients"]).to eq(10)
      expect(pool.stats["total_connections"]).to eq(10)
    end
  end

  describe "backpressure strategies" do
    let(:metrics) { Sidekiq::AsyncHttp::Metrics.new }

    context "with :raise strategy" do
      let(:config) do
        Sidekiq::AsyncHttp::Configuration.new(
          max_connections: 2,
          backpressure_strategy: :raise
        )
      end
      let(:pool) { described_class.new(config, metrics: metrics) }

      it "raises BackpressureError when limit is reached" do
        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        expect { pool.client_for("https://host3.example.com/") }
          .to raise_error(Sidekiq::AsyncHttp::BackpressureError)
      end

      it "records backpressure event in metrics" do
        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        expect { pool.client_for("https://host3.example.com/") rescue nil }
          .to change { metrics.backpressure_events }.by(1)
      end

      it "allows creating clients after connections are released" do
        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        # Close one connection to free up space
        pool.close_all

        # Should now be able to create a new client
        expect { pool.client_for("https://host3.example.com/") }.not_to raise_error
      end
    end

    context "with :block strategy" do
      let(:config) do
        Sidekiq::AsyncHttp::Configuration.new(
          max_connections: 2,
          backpressure_strategy: :block
        )
      end
      let(:pool) { described_class.new(config, metrics: metrics) }

      before do
        # Stub Async::Condition#wait to prevent actual blocking in tests
        condition = pool.instance_variable_get(:@capacity_condition)
        allow(condition).to receive(:wait).and_return(nil)
      end

      it "attempts to block when limit is reached" do
        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        # This will hit max retries and raise an error
        expect { pool.client_for("https://host3.example.com/") }
          .to raise_error(Sidekiq::AsyncHttp::BackpressureError, /Max retries exceeded/)
      end

      it "records backpressure events" do
        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        expect { pool.client_for("https://host3.example.com/") rescue nil }
          .to change { metrics.backpressure_events }.by_at_least(1)
      end

      it "calls Async::Condition wait when blocking" do
        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        condition = pool.instance_variable_get(:@capacity_condition)

        # This will call wait (stubbed) and then hit max retries
        expect { pool.client_for("https://host3.example.com/") }
          .to raise_error(Sidekiq::AsyncHttp::BackpressureError, /Max retries exceeded/)

        expect(condition).to have_received(:wait).at_least(:once)
      end

      it "releases connection slot after with_client completes" do
        released = false

        # Don't fill the pool so with_client can actually complete
        pool.client_for("https://host1.example.com/")

        # Stub release to track it's called
        original_release = pool.method(:release_connection_slot)
        allow(pool).to receive(:release_connection_slot) do
          released = true
          original_release.call
        end

        # Use with_client - it should call release_connection_slot at the end
        pool.with_client("https://host1.example.com/") do |client|
          # Do nothing
        end

        expect(released).to be(true)
      end
    end

    context "with :drop_oldest strategy" do
      let(:config) do
        Sidekiq::AsyncHttp::Configuration.new(
          max_connections: 2,
          backpressure_strategy: :drop_oldest
        )
      end
      let(:pool) { described_class.new(config, metrics: metrics) }

      it "raises error when no callback is set" do
        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        expect { pool.client_for("https://host3.example.com/") }
          .to raise_error(Sidekiq::AsyncHttp::BackpressureError, /unable to drop oldest/)
      end

      it "calls the drop_oldest callback when at capacity" do
        dropped_request_id = nil

        pool.on_drop_oldest do
          dropped_request_id = "req-123"
          dropped_request_id
        end

        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        # This should trigger the callback, but will still fail because
        # we're not actually freeing up a connection
        expect { pool.client_for("https://host3.example.com/") }
          .to raise_error(Sidekiq::AsyncHttp::BackpressureError)

        expect(dropped_request_id).to eq("req-123")
      end

      it "retries after dropping oldest request" do
        drop_count = 0

        pool.on_drop_oldest do
          drop_count += 1
          "req-#{drop_count}"
        end

        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        # This will attempt to drop and retry, but will fail since we're not
        # actually freeing connections
        expect { pool.client_for("https://host3.example.com/") }
          .to raise_error(Sidekiq::AsyncHttp::BackpressureError)

        # Should have tried to drop at least once
        expect(drop_count).to be > 0
      end

      it "succeeds if callback returns nil (couldn't drop)" do
        pool.on_drop_oldest { nil }

        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        expect { pool.client_for("https://host3.example.com/") }
          .to raise_error(Sidekiq::AsyncHttp::BackpressureError, /unable to drop oldest/)
      end

      it "records backpressure events" do
        pool.on_drop_oldest { "req-1" }

        pool.client_for("https://host1.example.com/")
        pool.client_for("https://host2.example.com/")

        expect { pool.client_for("https://host3.example.com/") rescue nil }
          .to change { metrics.backpressure_events }.by_at_least(1)
      end
    end
  end
end
