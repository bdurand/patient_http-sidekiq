# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::Stats do
  let(:stats) { described_class.new }

  describe "#record_request" do
    it "logs and swallows Redis errors outside of testing mode", :disable_testing_mode do
      allow(::Sidekiq).to receive(:redis).and_raise(RedisClient::CannotConnectError.new("redis down"))

      stats.record_request(200, 0.5)
      expect { stats.flush }.not_to raise_error
    end

    it "retains deltas when a flush fails and writes them on the next flush", :disable_testing_mode do
      stats.record_request(200, 0.5)

      allow(::Sidekiq).to receive(:redis).and_raise(RedisClient::CannotConnectError.new("redis down"))
      stats.flush
      allow(::Sidekiq).to receive(:redis).and_call_original

      stats.flush
      totals = stats.get_totals
      expect(totals["requests"]).to eq(1)
      expect(totals["duration"]).to eq(0.5)
    end

    it "records request with duration" do
      stats.record_request(200, 0.5)
      stats.record_request(200, 1.5)

      totals = stats.get_totals
      expect(totals["requests"]).to eq(2)
      expect(totals["duration"]).to eq(2.0)
    end

    it "records HTTP status counts" do
      stats.record_request(200, 0.5)
      stats.record_request(200, 1.0)
      stats.record_request(404, 0.3)
      stats.record_request(500, 1.2)

      totals = stats.get_totals
      expect(totals["http_status_counts"]).to eq(200 => 2, 404 => 1, 500 => 1)
    end

    it "handles nil status gracefully" do
      stats.record_request(nil, 0.5)
      stats.record_request(200, 1.0)

      totals = stats.get_totals
      expect(totals["requests"]).to eq(2)
      expect(totals["http_status_counts"]).to eq(200 => 1)
    end

    it "only records status codes in valid range (100-599)" do
      stats.record_request(99, 0.5)
      stats.record_request(200, 1.0)
      stats.record_request(600, 0.5)

      totals = stats.get_totals
      expect(totals["http_status_counts"]).to eq(200 => 1)
    end

    it "records different status code categories" do
      stats.record_request(200, 0.5) # 2xx Success
      stats.record_request(201, 0.5) # 2xx Success
      stats.record_request(301, 0.5) # 3xx Redirect
      stats.record_request(404, 0.5) # 4xx Client Error
      stats.record_request(422, 0.5) # 4xx Client Error
      stats.record_request(500, 0.5) # 5xx Server Error
      stats.record_request(503, 0.5) # 5xx Server Error

      totals = stats.get_totals
      expect(totals["http_status_counts"]).to eq(
        200 => 1,
        201 => 1,
        301 => 1,
        404 => 1,
        422 => 1,
        500 => 1,
        503 => 1
      )
    end
  end

  describe "#record_error" do
    it "increments error count" do
      stats.record_error(:timeout)
      stats.record_error(:timeout)

      totals = stats.get_totals
      expect(totals["errors"]).to eq(2)
    end
  end

  describe "#record_capacity_exceeded" do
    it "increments refused count" do
      stats.record_capacity_exceeded
      stats.record_capacity_exceeded

      totals = stats.get_totals
      expect(totals["max_capacity_exceeded"]).to eq(2)
    end
  end

  describe "#get_totals" do
    it "returns all totals" do
      stats.record_request(200, 0.5)
      stats.record_request(404, 1.5)
      stats.record_error(:timeout)
      stats.record_capacity_exceeded

      totals = stats.get_totals
      expect(totals["requests"]).to eq(2)
      expect(totals["duration"]).to eq(2.0)
      expect(totals["errors"]).to eq(1)
      expect(totals["max_capacity_exceeded"]).to eq(1)
      expect(totals["http_status_counts"]).to eq(200 => 1, 404 => 1)
    end

    it "returns zero values when no data" do
      totals = stats.get_totals
      expect(totals["requests"]).to eq(0)
      expect(totals["duration"]).to eq(0.0)
      expect(totals["errors"]).to eq(0)
      expect(totals["max_capacity_exceeded"]).to eq(0)
      expect(totals["http_status_counts"]).to eq({})
    end
  end

  describe "#reset!" do
    it "clears all stats" do
      stats.record_request(200, 0.5)
      stats.record_error(:timeout)
      stats.record_capacity_exceeded

      stats.reset!

      totals = stats.get_totals
      expect(totals["requests"]).to eq(0)
      expect(totals["errors"]).to eq(0)
      expect(totals["max_capacity_exceeded"]).to eq(0)
    end
  end

  describe "Redis integration" do
    it "stores and retrieves data from Redis" do
      stats.record_request(200, 0.5)
      stats.record_error(:timeout)
      stats.record_capacity_exceeded

      totals = stats.get_totals
      expect(totals["requests"]).to eq(1)
      expect(totals["errors"]).to eq(1)
      expect(totals["max_capacity_exceeded"]).to eq(1)
    end
  end

  describe "local aggregation" do
    it "does not write to Redis until flushed" do
      stats.record_request(200, 0.5)

      raw = ::Sidekiq.redis { |redis| redis.hgetall(described_class::TOTALS_KEY) }
      expect(raw).to eq({})

      stats.flush
      raw = ::Sidekiq.redis { |redis| redis.hgetall(described_class::TOTALS_KEY) }
      expect(raw["requests"]).to eq("1")
    end

    it "flushes synchronously when the flush interval is 0" do
      config = PatientHttp::Sidekiq::Configuration.new(stats_flush_interval: 0)
      synchronous_stats = described_class.new(config)

      synchronous_stats.record_request(200, 0.5)

      raw = ::Sidekiq.redis { |redis| redis.hgetall(described_class::TOTALS_KEY) }
      expect(raw["requests"]).to eq("1")
    end

    it "sums concurrent recordings exactly" do
      threads = Array.new(8) do
        Thread.new do
          25.times { stats.record_request(200, 0.1) }
        end
      end
      threads.each(&:join)

      totals = stats.get_totals
      expect(totals["requests"]).to eq(200)
      expect(totals["duration"]).to be_within(0.001).of(20.0)
    end

    it "flushes through flush_if_due only after the interval elapses" do
      config = PatientHttp::Sidekiq::Configuration.new(stats_flush_interval: 3600)
      slow_stats = described_class.new(config)
      slow_stats.record_request(200, 0.5)

      slow_stats.flush_if_due
      raw = ::Sidekiq.redis { |redis| redis.hgetall(described_class::TOTALS_KEY) }
      expect(raw).to eq({})

      slow_stats.flush
      raw = ::Sidekiq.redis { |redis| redis.hgetall(described_class::TOTALS_KEY) }
      expect(raw["requests"]).to eq("1")
    end
  end

  describe "per-processor stats" do
    it "records per-processor fields when a processor name is given" do
      stats.record_request(200, 0.5, processor_name: "llm")
      stats.record_request(200, 1.0, processor_name: "webhooks")
      stats.record_request(200, 0.25)

      totals = stats.get_totals
      expect(totals["requests"]).to eq(3)
      expect(totals["processors"]).to eq(
        "llm" => {"requests" => 1, "duration" => 0.5, "errors" => 0, "max_capacity_exceeded" => 0, "max_inflight" => 0},
        "webhooks" => {"requests" => 1, "duration" => 1.0, "errors" => 0, "max_capacity_exceeded" => 0, "max_inflight" => 0}
      )
    end

    it "records per-processor errors and capacity rejections" do
      stats.record_error("timeout", processor_name: "llm")
      stats.record_capacity_exceeded(processor_name: "llm")
      stats.record_capacity_exceeded(processor_name: "webhooks")

      totals = stats.get_totals
      expect(totals["errors"]).to eq(1)
      expect(totals["max_capacity_exceeded"]).to eq(2)
      expect(totals["processors"]).to eq(
        "llm" => {"requests" => 0, "duration" => 0.0, "errors" => 1, "max_capacity_exceeded" => 1, "max_inflight" => 0},
        "webhooks" => {"requests" => 0, "duration" => 0.0, "errors" => 0, "max_capacity_exceeded" => 1, "max_inflight" => 0}
      )
    end

    it "keeps the highest in-flight count recorded for a processor" do
      stats.record_inflight_peak(12, processor_name: "llm")
      stats.record_inflight_peak(30, processor_name: "llm")
      stats.record_inflight_peak(7, processor_name: "llm")
      stats.record_request(200, 0.5, processor_name: "llm")

      expect(stats.get_totals["processors"]["llm"]["max_inflight"]).to eq(30)
    end

    it "keeps the highest count recorded by any process" do
      other_stats = described_class.new

      stats.record_inflight_peak(30, processor_name: "llm")
      stats.record_request(200, 0.5, processor_name: "llm")
      other_stats.record_inflight_peak(12, processor_name: "llm")
      other_stats.record_request(200, 0.5, processor_name: "llm")

      expect(stats.get_totals["processors"]["llm"]["max_inflight"]).to eq(30)
    end

    it "records the high-water mark again after the totals are cleared" do
      stats.record_inflight_peak(30, processor_name: "llm")
      stats.record_request(200, 0.5, processor_name: "llm")
      expect(stats.get_totals["processors"]["llm"]["max_inflight"]).to eq(30)

      ::Sidekiq.redis { |redis| redis.del(described_class::TOTALS_KEY) }
      stats.record_request(200, 0.5, processor_name: "llm")

      expect(stats.get_totals["processors"]["llm"]["max_inflight"]).to eq(30)
    end

    it "forgets the high-water mark when the stats are reset" do
      stats.record_inflight_peak(30, processor_name: "llm")
      stats.record_request(200, 0.5, processor_name: "llm")
      stats.flush

      stats.reset!
      stats.record_request(200, 0.5, processor_name: "llm")

      expect(stats.get_totals["processors"]["llm"]["max_inflight"]).to eq(0)
    end

    it "records the mark with the EVAL fallback when the script is not cached" do
      stats.record_inflight_peak(30, processor_name: "llm")
      stats.record_request(200, 0.5, processor_name: "llm")
      ::Sidekiq.redis { |redis| redis.call("SCRIPT", "FLUSH") }

      expect(stats.get_totals["processors"]["llm"]["max_inflight"]).to eq(30)
    end

    it "ignores an in-flight count when only one processor profile is configured" do
      single = described_class.new(PatientHttp::Sidekiq::Configuration.new)

      single.record_inflight_peak(30, processor_name: "default")
      single.record_request(200, 0.5, processor_name: "default")

      expect(single.get_totals).not_to have_key("processors")
    end

    it "omits the processors key when no per-processor fields exist" do
      stats.record_request(200, 0.5)

      expect(stats.get_totals).not_to have_key("processors")
    end

    it "omits per-processor fields when only one processor profile is configured" do
      single = described_class.new(PatientHttp::Sidekiq::Configuration.new)

      single.record_request(200, 0.5, processor_name: "default")

      expect(single.get_totals).not_to have_key("processors")
    end

    it "records per-processor fields when more than one profile is configured" do
      config = PatientHttp::Sidekiq::Configuration.new
      config.processor(:llm, max_connections: 10)
      multiple = described_class.new(config)

      multiple.record_request(200, 0.5, processor_name: "llm")

      expect(multiple.get_totals["processors"]).to have_key("llm")
    end

    it "removes colons from the processor name so the field name stays parseable" do
      stats.record_request(200, 0.5, processor_name: "llm:v2")

      expect(stats.get_totals["processors"]).to have_key("llm-v2")
    end
  end
end
