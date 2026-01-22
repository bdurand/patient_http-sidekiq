# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Stats do
  let(:stats) { described_class.new }

  describe "#record_request" do
    it "records request with duration" do
      stats.record_request(0.5)
      stats.record_request(1.5)

      totals = stats.get_totals
      expect(totals["requests"]).to eq(2)
      expect(totals["duration"]).to eq(2.0)
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

  describe "#record_refused" do
    it "increments refused count" do
      stats.record_refused
      stats.record_refused

      totals = stats.get_totals
      expect(totals["refused"]).to eq(2)
    end
  end

  describe "#update_inflight" do
    it "updates inflight count for current process" do
      stats.update_inflight(5, 10)

      all_inflight = stats.get_all_inflight
      expect(all_inflight.values.first).to eq(count: 5, max: 10)
    end

    it "overwrites previous value" do
      stats.update_inflight(5, 10)
      stats.update_inflight(3, 10)

      all_inflight = stats.get_all_inflight
      expect(all_inflight.values.first).to eq(count: 3, max: 10)
    end
  end

  describe "#get_totals" do
    it "returns all totals" do
      stats.record_request(0.5)
      stats.record_request(1.5)
      stats.record_error(:timeout)
      stats.record_refused

      totals = stats.get_totals
      expect(totals["requests"]).to eq(2)
      expect(totals["duration"]).to eq(2.0)
      expect(totals["errors"]).to eq(1)
      expect(totals["refused"]).to eq(1)
    end

    it "returns zero values when no data" do
      totals = stats.get_totals
      expect(totals["requests"]).to eq(0)
      expect(totals["duration"]).to eq(0.0)
      expect(totals["errors"]).to eq(0)
      expect(totals["refused"]).to eq(0)
    end
  end

  describe "#get_all_inflight" do
    it "returns all inflight counts and max connections" do
      stats.update_inflight(5, 10)

      all_inflight = stats.get_all_inflight
      expect(all_inflight).to be_a(Hash)
      expect(all_inflight.values.map { |h| h[:count] }).to include(5)
      expect(all_inflight.values.map { |h| h[:max] }).to include(10)
    end

    it "returns empty hash when no inflight data" do
      all_inflight = stats.get_all_inflight
      expect(all_inflight).to eq({})
    end
  end

  describe "#get_total_inflight" do
    it "sums all inflight counts" do
      stats.update_inflight(5, 10)

      total = stats.get_total_inflight
      expect(total).to eq(5)
    end

    it "returns 0 when no inflight data" do
      total = stats.get_total_inflight
      expect(total).to eq(0)
    end
  end

  describe "#get_total_max_connections" do
    it "sums all max connections" do
      stats.update_inflight(5, 10)

      total = stats.get_total_max_connections
      expect(total).to eq(10)
    end

    it "returns 0 when no max connections data" do
      total = stats.get_total_max_connections
      expect(total).to eq(0)
    end
  end

  describe "#cleanup_process_keys" do
    it "removes inflight and max_connections keys for current process" do
      stats.update_inflight(5, 10)

      # Verify data exists
      expect(stats.get_all_inflight.values.map { |h| h[:count] }).to include(5)
      expect(stats.get_total_max_connections).to eq(10)

      # Cleanup
      stats.cleanup_process_keys

      # Verify data is removed
      expect(stats.get_all_inflight).to eq({})
      expect(stats.get_total_max_connections).to eq(0)
    end
  end

  describe "#reset!" do
    it "clears all stats" do
      stats.record_request(0.5)
      stats.record_error(:timeout)
      stats.record_refused
      stats.update_inflight(5, 10)

      stats.reset!

      totals = stats.get_totals
      expect(totals["requests"]).to eq(0)
      expect(totals["errors"]).to eq(0)
      expect(totals["refused"]).to eq(0)

      all_inflight = stats.get_all_inflight
      expect(all_inflight).to eq({})
    end
  end

  describe "Redis integration" do
    it "stores and retrieves data from Redis" do
      stats.record_request(0.5)
      stats.record_error(:timeout)
      stats.record_refused

      totals = stats.get_totals
      expect(totals["requests"]).to eq(1)
      expect(totals["errors"]).to eq(1)
      expect(totals["refused"]).to eq(1)
    end

    it "stores inflight data in Redis" do
      stats.update_inflight(5, 10)

      all_inflight = stats.get_all_inflight
      expect(all_inflight.values).to include({count: 5, max: 10})
    end
  end
end
