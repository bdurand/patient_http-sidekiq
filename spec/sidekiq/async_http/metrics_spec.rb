# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Metrics do
  let(:metrics) { described_class.new }
  let(:request) { TestRequest.new(id: "req-123") }

  describe "#initialize" do
    it "initializes with zero counts" do
      expect(metrics.in_flight_count).to eq(0)
      expect(metrics.total_requests).to eq(0)
      expect(metrics.error_count).to eq(0)
      expect(metrics.backpressure_events).to eq(0)
      expect(metrics.average_duration).to eq(0.0)
    end

    it "initializes with empty collections" do
      expect(metrics.in_flight_requests).to eq([])
      expect(metrics.errors_by_type).to eq({})
      expect(metrics.connections_per_host).to eq({})
    end
  end

  describe "#record_request_start" do
    it "adds request to in-flight requests" do
      metrics.record_request_start(request)

      expect(metrics.in_flight_count).to eq(1)
      expect(metrics.in_flight_requests).to include(request)
    end

    it "tracks multiple in-flight requests" do
      request1 = TestRequest.new(id: "req-1")
      request2 = TestRequest.new(id: "req-2")
      request3 = TestRequest.new(id: "req-3")

      metrics.record_request_start(request1)
      metrics.record_request_start(request2)
      metrics.record_request_start(request3)

      expect(metrics.in_flight_count).to eq(3)
      expect(metrics.in_flight_requests).to contain_exactly(request1, request2, request3)
    end
  end

  describe "#record_request_complete" do
    before do
      metrics.record_request_start(request)
    end

    it "removes request from in-flight requests" do
      metrics.record_request_complete(request, 0.5)

      expect(metrics.in_flight_count).to eq(0)
      expect(metrics.in_flight_requests).to be_empty
    end

    it "increments total requests" do
      expect { metrics.record_request_complete(request, 0.5) }
        .to change { metrics.total_requests }.from(0).to(1)
    end

    it "adds duration to total duration" do
      metrics.record_request_complete(request, 1.5)

      expect(metrics.average_duration).to eq(1.5)
    end

    it "calculates correct average with multiple requests" do
      request2 = TestRequest.new(id: "req-2")
      request3 = TestRequest.new(id: "req-3")

      metrics.record_request_start(request2)
      metrics.record_request_start(request3)

      metrics.record_request_complete(request, 1.0)
      metrics.record_request_complete(request2, 2.0)
      metrics.record_request_complete(request3, 3.0)

      expect(metrics.total_requests).to eq(3)
      expect(metrics.average_duration).to eq(2.0)
    end
  end

  describe "#record_error" do
    it "increments error count" do
      expect { metrics.record_error(request, :timeout) }
        .to change { metrics.error_count }.from(0).to(1)
    end

    it "tracks errors by type" do
      metrics.record_error(request, :timeout)

      expect(metrics.errors_by_type).to eq({timeout: 1})
    end

    it "increments existing error types" do
      request2 = TestRequest.new(id: "req-2")
      request3 = TestRequest.new(id: "req-3")

      metrics.record_error(request, :timeout)
      metrics.record_error(request2, :timeout)
      metrics.record_error(request3, :connection)

      expect(metrics.errors_by_type).to eq({timeout: 2, connection: 1})
      expect(metrics.error_count).to eq(3)
    end

    it "supports all error types" do
      error_types = %i[timeout connection ssl protocol unknown]

      error_types.each_with_index do |type, index|
        req = TestRequest.new(id: "req-#{index}")
        metrics.record_error(req, type)
      end

      expect(metrics.errors_by_type.keys).to match_array(error_types)
      expect(metrics.error_count).to eq(5)
    end
  end

  describe "#record_backpressure" do
    it "increments backpressure events" do
      expect { metrics.record_backpressure }
        .to change { metrics.backpressure_events }.from(0).to(1)
    end

    it "tracks multiple backpressure events" do
      3.times { metrics.record_backpressure }

      expect(metrics.backpressure_events).to eq(3)
    end
  end

  describe "#update_connections" do
    it "sets connection count for new host" do
      metrics.update_connections("api.example.com", 5)

      expect(metrics.connections_per_host["api.example.com"]).to eq(5)
    end

    it "increments connection count for existing host" do
      metrics.update_connections("api.example.com", 3)
      metrics.update_connections("api.example.com", 2)

      expect(metrics.connections_per_host["api.example.com"]).to eq(5)
    end

    it "decrements connection count" do
      metrics.update_connections("api.example.com", 10)
      metrics.update_connections("api.example.com", -3)

      expect(metrics.connections_per_host["api.example.com"]).to eq(7)
    end

    it "tracks multiple hosts" do
      metrics.update_connections("api.example.com", 5)
      metrics.update_connections("auth.example.com", 3)
      metrics.update_connections("cdn.example.com", 2)

      expect(metrics.connections_per_host).to eq({
        "api.example.com" => 5,
        "auth.example.com" => 3,
        "cdn.example.com" => 2
      })
    end

    it "does not allow negative connection counts for new hosts" do
      metrics.update_connections("api.example.com", -5)

      expect(metrics.connections_per_host["api.example.com"]).to eq(0)
    end
  end

  describe "#in_flight_requests" do
    it "returns frozen array" do
      result = metrics.in_flight_requests

      expect(result).to be_frozen
    end

    it "returns snapshot at time of call" do
      request1 = TestRequest.new(id: "req-1")
      request2 = TestRequest.new(id: "req-2")

      metrics.record_request_start(request1)
      snapshot = metrics.in_flight_requests
      metrics.record_request_start(request2)

      expect(snapshot.size).to eq(1)
      expect(metrics.in_flight_requests.size).to eq(2)
    end
  end

  describe "#errors_by_type" do
    it "returns frozen hash" do
      metrics.record_error(request, :timeout)
      result = metrics.errors_by_type

      expect(result).to be_frozen
    end

    it "returns snapshot at time of call" do
      metrics.record_error(request, :timeout)
      snapshot = metrics.errors_by_type

      request2 = TestRequest.new(id: "req-2")
      metrics.record_error(request2, :connection)

      expect(snapshot).to eq({timeout: 1})
      expect(metrics.errors_by_type).to eq({timeout: 1, connection: 1})
    end
  end

  describe "#connections_per_host" do
    it "returns frozen hash" do
      metrics.update_connections("api.example.com", 5)
      result = metrics.connections_per_host

      expect(result).to be_frozen
    end

    it "returns snapshot at time of call" do
      metrics.update_connections("api.example.com", 5)
      snapshot = metrics.connections_per_host
      metrics.update_connections("auth.example.com", 3)

      expect(snapshot).to eq({"api.example.com" => 5})
      expect(metrics.connections_per_host.keys.size).to eq(2)
    end
  end

  describe "#to_h" do
    it "returns hash with all metrics" do
      metrics.record_request_start(request)
      metrics.record_request_complete(request, 1.5)
      metrics.record_error(request, :timeout)
      metrics.record_backpressure
      metrics.update_connections("api.example.com", 5)

      hash = metrics.to_h

      expect(hash).to be_a(Hash)
      expect(hash["in_flight_count"]).to eq(0)
      expect(hash["total_requests"]).to eq(1)
      expect(hash["average_duration"]).to eq(1.5)
      expect(hash["error_count"]).to eq(1)
      expect(hash["errors_by_type"]).to eq({timeout: 1})
      expect(hash["connections_per_host"]).to eq({"api.example.com" => 5})
      expect(hash["backpressure_events"]).to eq(1)
    end

    it "returns consistent snapshot" do
      10.times do |i|
        req = TestRequest.new(id: "req-#{i}")
        metrics.record_request_start(req)
        metrics.record_request_complete(req, 1.0)
      end

      hash = metrics.to_h

      expect(hash["total_requests"]).to eq(10)
      expect(hash["average_duration"]).to eq(1.0)
    end
  end

  describe "#reset!" do
    before do
      metrics.record_request_start(request)
      metrics.record_request_complete(request, 1.5)
      metrics.record_error(request, :timeout)
      metrics.record_backpressure
      metrics.update_connections("api.example.com", 5)
    end

    it "resets all counters to zero" do
      metrics.reset!

      expect(metrics.in_flight_count).to eq(0)
      expect(metrics.total_requests).to eq(0)
      expect(metrics.error_count).to eq(0)
      expect(metrics.backpressure_events).to eq(0)
      expect(metrics.average_duration).to eq(0.0)
    end

    it "clears all collections" do
      metrics.reset!

      expect(metrics.in_flight_requests).to be_empty
      expect(metrics.errors_by_type).to be_empty
      expect(metrics.connections_per_host).to be_empty
    end
  end

  describe "thread safety", :slow do
    it "handles concurrent request tracking" do
      threads = []
      num_threads = 10
      requests_per_thread = 100

      num_threads.times do |i|
        threads << Thread.new do
          requests_per_thread.times do |j|
            req = TestRequest.new(id: "req-#{i}-#{j}")
            metrics.record_request_start(req)
            metrics.record_request_complete(req, rand(0.1..2.0))
          end
        end
      end

      threads.each(&:join)

      expect(metrics.total_requests).to eq(num_threads * requests_per_thread)
      expect(metrics.in_flight_count).to eq(0)
    end

    it "handles concurrent error recording" do
      threads = []
      num_threads = 10
      errors_per_thread = 50
      error_types = %i[timeout connection ssl protocol unknown]

      num_threads.times do |i|
        threads << Thread.new do
          errors_per_thread.times do |j|
            req = TestRequest.new(id: "req-#{i}-#{j}")
            error_type = error_types.sample
            metrics.record_error(req, error_type)
          end
        end
      end

      threads.each(&:join)

      expect(metrics.error_count).to eq(num_threads * errors_per_thread)

      # Sum of all error types should equal total error count
      total_by_type = metrics.errors_by_type.values.sum
      expect(total_by_type).to eq(metrics.error_count)
    end

    it "handles concurrent connection updates" do
      threads = []
      num_threads = 10
      updates_per_thread = 100
      hosts = %w[api.example.com auth.example.com cdn.example.com]

      num_threads.times do
        threads << Thread.new do
          updates_per_thread.times do
            host = hosts.sample
            delta = rand(-2..5)
            metrics.update_connections(host, delta)
          end
        end
      end

      threads.each(&:join)

      # Just verify it doesn't crash and maintains some connection state
      expect(metrics.connections_per_host.keys).not_to be_empty
    end

    it "handles concurrent backpressure recording" do
      threads = []
      num_threads = 10
      events_per_thread = 100

      num_threads.times do
        threads << Thread.new do
          events_per_thread.times do
            metrics.record_backpressure
          end
        end
      end

      threads.each(&:join)

      expect(metrics.backpressure_events).to eq(num_threads * events_per_thread)
    end

    it "handles mixed concurrent operations" do
      threads = []
      num_operations = 500

      # Thread 1: Start requests
      threads << Thread.new do
        num_operations.times do |i|
          req = TestRequest.new(id: "req-1-#{i}")
          metrics.record_request_start(req)
        end
      end

      # Thread 2: Complete requests
      threads << Thread.new do
        num_operations.times do |i|
          req = TestRequest.new(id: "req-2-#{i}")
          metrics.record_request_start(req)
          metrics.record_request_complete(req, rand(0.1..2.0))
        end
      end

      # Thread 3: Record errors
      threads << Thread.new do
        num_operations.times do |i|
          req = TestRequest.new(id: "req-3-#{i}")
          metrics.record_error(req, :timeout)
        end
      end

      # Thread 4: Update connections
      threads << Thread.new do
        num_operations.times do
          metrics.update_connections("api.example.com", rand(-1..2))
        end
      end

      threads.each(&:join)

      # Verify no crashes and data consistency
      expect(metrics.total_requests).to eq(num_operations)
      expect(metrics.error_count).to eq(num_operations)
      expect(metrics.to_h).to be_a(Hash)
    end
  end
end
