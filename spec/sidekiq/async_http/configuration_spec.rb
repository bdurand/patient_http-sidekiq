# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Configuration do
  describe "#initialize" do
    context "with no arguments" do
      it "uses default values" do
        config = described_class.new

        expect(config.max_connections).to eq(256)
        expect(config.idle_connection_timeout).to eq(60)
        expect(config.default_request_timeout).to eq(60)
        expect(config.shutdown_timeout).to eq(Sidekiq.default_configuration[:timeout] - 2)
        expect(config.logger).to eq(Sidekiq.logger)
        expect(config.raise_error_responses).to eq(false)
      end
    end

    context "with custom values" do
      it "uses provided values" do
        custom_logger = Logger.new($stdout)
        config = described_class.new(
          max_connections: 512,
          idle_connection_timeout: 120,
          default_request_timeout: 60,
          shutdown_timeout: 30,
          logger: custom_logger,
          raise_error_responses: true
        )

        expect(config.max_connections).to eq(512)
        expect(config.idle_connection_timeout).to eq(120)
        expect(config.default_request_timeout).to eq(60)
        expect(config.shutdown_timeout).to eq(30)
        expect(config.logger).to eq(custom_logger)
        expect(config.raise_error_responses).to eq(true)
      end
    end

    context "with partial custom values" do
      it "merges with defaults" do
        config = described_class.new(
          max_connections: 1024
        )

        expect(config.max_connections).to eq(1024)
        expect(config.idle_connection_timeout).to eq(60) # default
      end
    end
  end

  describe "validation" do
    context "with invalid max_connections" do
      it "raises ArgumentError for zero" do
        expect { described_class.new(max_connections: 0) }.to raise_error(
          ArgumentError,
          "max_connections must be a positive number, got: 0"
        )
      end

      it "raises ArgumentError for negative" do
        expect { described_class.new(max_connections: -1) }.to raise_error(
          ArgumentError,
          "max_connections must be a positive number, got: -1"
        )
      end

      it "raises ArgumentError for non-numeric" do
        expect { described_class.new(max_connections: "256") }.to raise_error(
          ArgumentError,
          /max_connections must be a positive number/
        )
      end
    end

    context "with invalid idle_connection_timeout" do
      it "raises ArgumentError for zero" do
        expect { described_class.new(idle_connection_timeout: 0) }.to raise_error(
          ArgumentError,
          "idle_connection_timeout must be a positive number, got: 0"
        )
      end

      it "raises ArgumentError for negative" do
        expect { described_class.new(idle_connection_timeout: -10) }.to raise_error(
          ArgumentError,
          "idle_connection_timeout must be a positive number, got: -10"
        )
      end
    end

    context "with invalid default_request_timeout" do
      it "raises ArgumentError for zero" do
        expect { described_class.new(default_request_timeout: 0) }.to raise_error(
          ArgumentError,
          "default_request_timeout must be a positive number, got: 0"
        )
      end
    end

    context "with invalid shutdown_timeout" do
      it "raises ArgumentError for zero" do
        expect { described_class.new(shutdown_timeout: 0) }.to raise_error(
          ArgumentError,
          "shutdown_timeout must be a positive number, got: 0"
        )
      end
    end

    context "with float values" do
      it "accepts positive floats for timeouts" do
        described_class.new(
          idle_connection_timeout: 30.5,
          default_request_timeout: 15.25,
          shutdown_timeout: 20.75
        )
      end
    end

    context "with invalid heartbeat_interval and orphan_threshold relationship" do
      it "raises ArgumentError when heartbeat_interval >= orphan_threshold" do
        expect { described_class.new(heartbeat_interval: 300, orphan_threshold: 300) }.to raise_error(
          ArgumentError,
          "heartbeat_interval (300) must be less than orphan_threshold (300)"
        )
      end

      it "raises ArgumentError when heartbeat_interval > orphan_threshold" do
        expect { described_class.new(heartbeat_interval: 400, orphan_threshold: 300) }.to raise_error(
          ArgumentError,
          "heartbeat_interval (400) must be less than orphan_threshold (300)"
        )
      end

      it "allows heartbeat_interval < orphan_threshold" do
        expect do
          described_class.new(heartbeat_interval: 60, orphan_threshold: 300)
        end.not_to raise_error
      end
    end
  end

  describe "#logger" do
    context "when logger is configured" do
      it "returns the configured logger" do
        custom_logger = Logger.new($stdout)
        config = described_class.new(logger: custom_logger)

        expect(config.logger).to eq(custom_logger)
      end
    end

    context "when logger is not configured" do
      it "returns Sidekiq.logger if available" do
        config = described_class.new(logger: nil)
        allow(Sidekiq).to receive(:logger).and_return(:sidekiq_logger)

        expect(config.logger).to eq(:sidekiq_logger)
      end
    end
  end

  describe "#to_h" do
    it "returns hash with string keys" do
      custom_logger = Logger.new($stdout)
      config = described_class.new(
        max_connections: 512,
        idle_connection_timeout: 120,
        default_request_timeout: 60,
        shutdown_timeout: 30,
        logger: custom_logger
      )

      hash = config.to_h

      expect(hash).to be_a(Hash)
      expect(hash["max_connections"]).to eq(512)
      expect(hash["idle_connection_timeout"]).to eq(120)
      expect(hash["default_request_timeout"]).to eq(60)
      expect(hash["shutdown_timeout"]).to eq(30)
      expect(hash["logger"]).to eq(custom_logger)
      expect(hash["raise_error_responses"]).to eq(false)
    end
  end
end
