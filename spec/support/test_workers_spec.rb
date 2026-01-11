# frozen_string_literal: true

require "spec_helper"

RSpec.describe TestWorkers do
  describe TestWorkers::Worker do
    before do
      described_class.reset_calls!
    end

    it "records calls to class variable" do
      expect(described_class.calls).to be_empty

      described_class.new.perform("arg1", "arg2")

      expect(described_class.calls).to eq([["arg1", "arg2"]])
    end

    it "records multiple calls" do
      described_class.new.perform("first")
      described_class.new.perform("second", "arg")

      expect(described_class.calls.size).to eq(2)
      expect(described_class.calls[0]).to eq(["first"])
      expect(described_class.calls[1]).to eq(["second", "arg"])
    end

    it "is thread-safe" do
      threads = 10.times.map do |i|
        Thread.new { described_class.new.perform("thread-#{i}") }
      end

      threads.each(&:join)

      expect(described_class.calls.size).to eq(10)
    end

    it "can be reset" do
      described_class.new.perform("arg")
      expect(described_class.calls.size).to eq(1)

      described_class.reset_calls!

      expect(described_class.calls).to be_empty
    end
  end

  describe TestWorkers::SuccessWorker do
    before do
      described_class.reset_calls!
    end

    it "records response and args" do
      response = {"status" => 200, "body" => "OK"}
      described_class.new.perform(response, "extra_arg")

      expect(described_class.calls.size).to eq(1)
      expect(described_class.calls.first).to eq([response, "extra_arg"])
    end

    it "records multiple calls" do
      described_class.new.perform({"status" => 200}, "arg1")
      described_class.new.perform({"status" => 201}, "arg2")

      expect(described_class.calls.size).to eq(2)
      expect(described_class.calls[0][0]["status"]).to eq(200)
      expect(described_class.calls[1][0]["status"]).to eq(201)
    end

    it "is thread-safe" do
      threads = 5.times.map do |i|
        Thread.new { described_class.new.perform({"index" => i}, "arg") }
      end

      threads.each(&:join)

      expect(described_class.calls.size).to eq(5)
    end

    it "can be reset" do
      described_class.new.perform({"status" => 200})
      described_class.reset_calls!

      expect(described_class.calls).to be_empty
    end
  end

  describe TestWorkers::ErrorWorker do
    before do
      described_class.reset_calls!
    end

    it "records error and args" do
      error = {"class_name" => "Timeout", "message" => "Request timed out"}
      described_class.new.perform(error, "extra_arg")

      expect(described_class.calls.size).to eq(1)
      expect(described_class.calls.first).to eq([error, "extra_arg"])
    end

    it "records multiple calls" do
      described_class.new.perform({"error_type" => "timeout"}, "arg1")
      described_class.new.perform({"error_type" => "connection"}, "arg2")

      expect(described_class.calls.size).to eq(2)
      expect(described_class.calls[0][0]["error_type"]).to eq("timeout")
      expect(described_class.calls[1][0]["error_type"]).to eq("connection")
    end

    it "is thread-safe" do
      threads = 5.times.map do |i|
        Thread.new { described_class.new.perform({"index" => i}, "arg") }
      end

      threads.each(&:join)

      expect(described_class.calls.size).to eq(5)
    end

    it "can be reset" do
      described_class.new.perform({"error_type" => "timeout"})
      described_class.reset_calls!

      expect(described_class.calls).to be_empty
    end
  end
end
