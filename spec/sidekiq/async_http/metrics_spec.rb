# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Metrics do
  let(:metrics) { described_class.new }
  let(:request) do
    create_request_task
  end

  def create_request_task(method: :get, url: "https://api.example.com/users")
    req = Sidekiq::AsyncHttp::Request.new(
      method: method,
      url: url
    )
    Sidekiq::AsyncHttp::RequestTask.new(
      request: req,
      sidekiq_job: {"class" => "TestWorkers::Worker", "jid" => "jid-123", "args" => []},
      success_worker: "TestWorkers::SuccessWorker"
    )
  end

  describe "#initialize" do
    it "initializes with zero counts" do
      expect(metrics.in_flight_count).to eq(0)
      expect(metrics.total_requests).to eq(0)
      expect(metrics.error_count).to eq(0)
      expect(metrics.average_duration).to eq(0.0)
    end

    it "initializes with empty collections" do
      expect(metrics.errors_by_type).to eq({})
    end
  end

  describe "#record_request_start" do
    it "adds request to in-flight requests" do
      metrics.record_request_start(request)

      expect(metrics.in_flight_count).to eq(1)
    end

    it "tracks multiple in-flight requests" do
      request1 = create_request_task
      request2 = create_request_task
      request3 = create_request_task

      metrics.record_request_start(request1)
      metrics.record_request_start(request2)
      metrics.record_request_start(request3)

      expect(metrics.in_flight_count).to eq(3)
    end
  end

  describe "#record_request_complete" do
    before do
      metrics.record_request_start(request)
    end

    it "removes request from in-flight requests" do
      metrics.record_request_complete(request, 0.5)

      expect(metrics.in_flight_count).to eq(0)
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
      request2 = create_request_task
      request3 = create_request_task

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
      request2 = create_request_task
      request3 = create_request_task

      metrics.record_error(request, :timeout)
      metrics.record_error(request2, :timeout)
      metrics.record_error(request3, :connection)

      expect(metrics.errors_by_type).to eq({timeout: 2, connection: 1})
      expect(metrics.error_count).to eq(3)
    end

    it "supports all error types" do
      error_types = %i[timeout connection ssl protocol unknown]

      error_types.each_with_index do |type, index|
        req = create_request_task
        metrics.record_error(req, type)
      end

      expect(metrics.errors_by_type.keys).to match_array(error_types)
      expect(metrics.error_count).to eq(5)
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

      request2 = create_request_task
      metrics.record_error(request2, :connection)

      expect(snapshot).to eq({timeout: 1})
      expect(metrics.errors_by_type).to eq({timeout: 1, connection: 1})
    end
  end

  describe "#to_h" do
    it "returns hash with all metrics" do
      metrics.record_request_start(request)
      metrics.record_request_complete(request, 1.5)
      metrics.record_error(request, :timeout)

      hash = metrics.to_h

      expect(hash).to be_a(Hash)
      expect(hash["in_flight_count"]).to eq(0)
      expect(hash["total_requests"]).to eq(1)
      expect(hash["average_duration"]).to eq(1.5)
      expect(hash["error_count"]).to eq(1)
      expect(hash["errors_by_type"]).to eq({timeout: 1})
    end

    it "returns consistent snapshot" do
      10.times do |i|
        req = create_request_task
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
    end

    it "resets all counters to zero" do
      metrics.reset!

      expect(metrics.in_flight_count).to eq(0)
      expect(metrics.total_requests).to eq(0)
      expect(metrics.error_count).to eq(0)
      expect(metrics.average_duration).to eq(0.0)
    end

    it "clears all collections" do
      metrics.reset!

      expect(metrics.errors_by_type).to be_empty
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
            req = create_request_task
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
            req = create_request_task
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
  end
end
