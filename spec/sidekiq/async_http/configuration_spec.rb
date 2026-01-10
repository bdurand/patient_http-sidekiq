# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Configuration do
  describe "VALID_BACKPRESSURE_STRATEGIES" do
    it "defines valid strategies" do
      expect(described_class::VALID_BACKPRESSURE_STRATEGIES).to eq(%i[block raise drop_oldest])
    end

    it "is frozen" do
      expect(described_class::VALID_BACKPRESSURE_STRATEGIES).to be_frozen
    end
  end

  describe "#initialize" do
    context "with no arguments" do
      it "uses default values" do
        config = described_class.new

        expect(config.max_connections).to eq(256)
        expect(config.idle_connection_timeout).to eq(60)
        expect(config.default_request_timeout).to eq(30)
        expect(config.shutdown_timeout).to eq(25)
        expect(config.logger).to be_nil
        expect(config.enable_http2).to be(true)
        expect(config.dns_cache_ttl).to eq(300)
        expect(config.backpressure_strategy).to eq(:raise)
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
          enable_http2: false,
          dns_cache_ttl: 600,
          backpressure_strategy: :block
        )

        expect(config.max_connections).to eq(512)
        expect(config.idle_connection_timeout).to eq(120)
        expect(config.default_request_timeout).to eq(60)
        expect(config.shutdown_timeout).to eq(30)
        expect(config.logger).to eq(custom_logger)
        expect(config.enable_http2).to be(false)
        expect(config.dns_cache_ttl).to eq(600)
        expect(config.backpressure_strategy).to eq(:block)
      end
    end

    context "with partial custom values" do
      it "merges with defaults" do
        config = described_class.new(
          max_connections: 1024,
          backpressure_strategy: :drop_oldest
        )

        expect(config.max_connections).to eq(1024)
        expect(config.idle_connection_timeout).to eq(60) # default
        expect(config.backpressure_strategy).to eq(:drop_oldest)
      end
    end
  end

  describe "#validate!" do
    context "with valid configuration" do
      it "returns self" do
        config = described_class.new
        expect(config.validate!).to eq(config)
      end

      it "does not raise an error" do
        config = described_class.new
        expect { config.validate! }.not_to raise_error
      end
    end

    context "with invalid max_connections" do
      it "raises ArgumentError for zero" do
        config = described_class.new(max_connections: 0)
        expect { config.validate! }.to raise_error(
          ArgumentError,
          "max_connections must be a positive number, got: 0"
        )
      end

      it "raises ArgumentError for negative" do
        config = described_class.new(max_connections: -1)
        expect { config.validate! }.to raise_error(
          ArgumentError,
          "max_connections must be a positive number, got: -1"
        )
      end

      it "raises ArgumentError for non-numeric" do
        config = described_class.new(max_connections: "256")
        expect { config.validate! }.to raise_error(
          ArgumentError,
          /max_connections must be a positive number/
        )
      end
    end

    context "with invalid idle_connection_timeout" do
      it "raises ArgumentError for zero" do
        config = described_class.new(idle_connection_timeout: 0)
        expect { config.validate! }.to raise_error(
          ArgumentError,
          "idle_connection_timeout must be a positive number, got: 0"
        )
      end

      it "raises ArgumentError for negative" do
        config = described_class.new(idle_connection_timeout: -10)
        expect { config.validate! }.to raise_error(
          ArgumentError,
          "idle_connection_timeout must be a positive number, got: -10"
        )
      end
    end

    context "with invalid default_request_timeout" do
      it "raises ArgumentError for zero" do
        config = described_class.new(default_request_timeout: 0)
        expect { config.validate! }.to raise_error(
          ArgumentError,
          "default_request_timeout must be a positive number, got: 0"
        )
      end
    end

    context "with invalid shutdown_timeout" do
      it "raises ArgumentError for zero" do
        config = described_class.new(shutdown_timeout: 0)
        expect { config.validate! }.to raise_error(
          ArgumentError,
          "shutdown_timeout must be a positive number, got: 0"
        )
      end
    end

    context "with invalid dns_cache_ttl" do
      it "raises ArgumentError for zero" do
        config = described_class.new(dns_cache_ttl: 0)
        expect { config.validate! }.to raise_error(
          ArgumentError,
          "dns_cache_ttl must be a positive number, got: 0"
        )
      end
    end

    context "with invalid backpressure_strategy" do
      it "raises ArgumentError for invalid symbol" do
        config = described_class.new(backpressure_strategy: :invalid)
        expect { config.validate! }.to raise_error(
          ArgumentError,
          /backpressure_strategy must be one of/
        )
      end

      it "raises ArgumentError for string" do
        config = described_class.new(backpressure_strategy: "raise")
        expect { config.validate! }.to raise_error(
          ArgumentError,
          /backpressure_strategy must be one of/
        )
      end

      it "raises ArgumentError for nil" do
        config = described_class.new(backpressure_strategy: nil)
        expect { config.validate! }.to raise_error(
          ArgumentError,
          /backpressure_strategy must be one of/
        )
      end
    end

    context "with all valid backpressure strategies" do
      it "accepts :block" do
        config = described_class.new(backpressure_strategy: :block)
        expect { config.validate! }.not_to raise_error
      end

      it "accepts :raise" do
        config = described_class.new(backpressure_strategy: :raise)
        expect { config.validate! }.not_to raise_error
      end

      it "accepts :drop_oldest" do
        config = described_class.new(backpressure_strategy: :drop_oldest)
        expect { config.validate! }.not_to raise_error
      end
    end

    context "with float values" do
      it "accepts positive floats for timeouts" do
        config = described_class.new(
          idle_connection_timeout: 30.5,
          default_request_timeout: 15.25,
          shutdown_timeout: 20.75
        )
        expect { config.validate! }.not_to raise_error
      end
    end
  end

  describe "#effective_logger" do
    context "when logger is configured" do
      it "returns the configured logger" do
        custom_logger = Logger.new($stdout)
        config = described_class.new(logger: custom_logger)

        expect(config.effective_logger).to eq(custom_logger)
      end
    end

    context "when logger is not configured" do
      it "returns Sidekiq.logger if available" do
        config = described_class.new(logger: nil)
        allow(Sidekiq).to receive(:logger).and_return(:sidekiq_logger)

        expect(config.effective_logger).to eq(:sidekiq_logger)
      end

      it "returns nil if Sidekiq is not defined" do
        config = described_class.new(logger: nil)
        hide_const("Sidekiq")

        expect(config.effective_logger).to be_nil
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
        logger: custom_logger,
        enable_http2: false,
        dns_cache_ttl: 600,
        backpressure_strategy: :block
      )

      hash = config.to_h

      expect(hash).to be_a(Hash)
      expect(hash["max_connections"]).to eq(512)
      expect(hash["idle_connection_timeout"]).to eq(120)
      expect(hash["default_request_timeout"]).to eq(60)
      expect(hash["shutdown_timeout"]).to eq(30)
      expect(hash["logger"]).to include("Logger")
      expect(hash["enable_http2"]).to be(false)
      expect(hash["dns_cache_ttl"]).to eq(600)
      expect(hash["backpressure_strategy"]).to eq("block")
    end

    it "converts backpressure_strategy to string" do
      config = described_class.new(backpressure_strategy: :raise)
      expect(config.to_h["backpressure_strategy"]).to eq("raise")
    end

    it "includes logger.inspect representation" do
      config = described_class.new(logger: nil)
      expect(config.to_h["logger"]).to eq("nil")
    end
  end

  describe "immutability" do
    it "is immutable" do
      config = described_class.new
      expect(config).to be_frozen
    end

    it "can create modified copies with #with" do
      config = described_class.new(max_connections: 256)
      new_config = config.with(max_connections: 512)

      expect(config.max_connections).to eq(256)
      expect(new_config.max_connections).to eq(512)
      expect(config).not_to eq(new_config)
    end
  end
end

RSpec.describe Sidekiq::AsyncHttp::Builder do
  describe "#initialize" do
    it "sets default values" do
      builder = described_class.new

      expect(builder.max_connections).to eq(256)
      expect(builder.idle_connection_timeout).to eq(60)
      expect(builder.default_request_timeout).to eq(30)
      expect(builder.shutdown_timeout).to eq(25)
      expect(builder.logger).to be_nil
      expect(builder.enable_http2).to be(true)
      expect(builder.dns_cache_ttl).to eq(300)
      expect(builder.backpressure_strategy).to eq(:raise)
    end
  end

  describe "attribute setters" do
    it "allows setting all attributes" do
      builder = described_class.new
      custom_logger = Logger.new($stdout)

      builder.max_connections = 512
      builder.idle_connection_timeout = 120
      builder.default_request_timeout = 60
      builder.shutdown_timeout = 30
      builder.logger = custom_logger
      builder.enable_http2 = false
      builder.dns_cache_ttl = 600
      builder.backpressure_strategy = :block

      expect(builder.max_connections).to eq(512)
      expect(builder.idle_connection_timeout).to eq(120)
      expect(builder.default_request_timeout).to eq(60)
      expect(builder.shutdown_timeout).to eq(30)
      expect(builder.logger).to eq(custom_logger)
      expect(builder.enable_http2).to be(false)
      expect(builder.dns_cache_ttl).to eq(600)
      expect(builder.backpressure_strategy).to eq(:block)
    end
  end

  describe "#build" do
    it "creates a Configuration with current values" do
      builder = described_class.new
      builder.max_connections = 512
      builder.backpressure_strategy = :block

      config = builder.build

      expect(config).to be_a(Sidekiq::AsyncHttp::Configuration)
      expect(config.max_connections).to eq(512)
      expect(config.backpressure_strategy).to eq(:block)
    end

    it "includes all builder attributes in the configuration" do
      builder = described_class.new
      custom_logger = Logger.new($stdout)

      builder.max_connections = 1024
      builder.idle_connection_timeout = 90
      builder.default_request_timeout = 45
      builder.shutdown_timeout = 35
      builder.logger = custom_logger
      builder.enable_http2 = false
      builder.dns_cache_ttl = 450
      builder.backpressure_strategy = :drop_oldest

      config = builder.build

      expect(config.max_connections).to eq(1024)
      expect(config.idle_connection_timeout).to eq(90)
      expect(config.default_request_timeout).to eq(45)
      expect(config.shutdown_timeout).to eq(35)
      expect(config.logger).to eq(custom_logger)
      expect(config.enable_http2).to be(false)
      expect(config.dns_cache_ttl).to eq(450)
      expect(config.backpressure_strategy).to eq(:drop_oldest)
    end

    it "validates the configuration" do
      builder = described_class.new
      builder.max_connections = -1

      expect { builder.build }.to raise_error(
        ArgumentError,
        /max_connections must be a positive number/
      )
    end

    it "returns an immutable Configuration" do
      builder = described_class.new
      config = builder.build

      expect(config).to be_frozen
    end

    it "validates backpressure_strategy" do
      builder = described_class.new
      builder.backpressure_strategy = :invalid

      expect { builder.build }.to raise_error(
        ArgumentError,
        /backpressure_strategy must be one of/
      )
    end
  end

  describe "builder pattern" do
    it "can be used to configure step by step" do
      builder = described_class.new
      builder.max_connections = 128
      builder.enable_http2 = false

      config = builder.build

      expect(config.max_connections).to eq(128)
      expect(config.enable_http2).to be(false)
      expect(config.idle_connection_timeout).to eq(60) # default preserved
    end
  end
end
