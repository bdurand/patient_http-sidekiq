# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Stats do
  let(:stats) { described_class.new }

  describe "#record_request" do
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
end
