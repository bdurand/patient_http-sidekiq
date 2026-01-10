# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp do
  describe "VERSION" do
    it "has a version number" do
      expect(Sidekiq::AsyncHttp::VERSION).to eq(File.read(File.join(__dir__, "../../VERSION")).strip)
    end
  end

  describe ".configure" do
    after do
      described_class.reset_configuration!
    end

    it "yields a Builder instance" do
      expect { |b| described_class.configure(&b) }.to yield_with_args(Sidekiq::AsyncHttp::Builder)
    end

    it "builds and stores a Configuration" do
      config = described_class.configure do |c|
        c.max_connections = 512
        c.backpressure_strategy = :block
      end

      expect(config).to be_a(Sidekiq::AsyncHttp::Configuration)
      expect(config.max_connections).to eq(512)
      expect(config.backpressure_strategy).to eq(:block)
    end

    it "returns the built configuration" do
      config = described_class.configure do |c|
        c.max_connections = 1024
      end

      expect(described_class.configuration).to eq(config)
    end

    it "validates configuration during build" do
      expect do
        described_class.configure do |c|
          c.max_connections = -1
        end
      end.to raise_error(ArgumentError, /max_connections must be a positive number/)
    end

    it "allows setting all configuration options" do
      custom_logger = Logger.new($stdout)

      config = described_class.configure do |c|
        c.max_connections = 512
        c.idle_connection_timeout = 120
        c.default_request_timeout = 60
        c.shutdown_timeout = 30
        c.logger = custom_logger
        c.enable_http2 = false
        c.dns_cache_ttl = 600
        c.backpressure_strategy = :drop_oldest
      end

      expect(config.max_connections).to eq(512)
      expect(config.idle_connection_timeout).to eq(120)
      expect(config.default_request_timeout).to eq(60)
      expect(config.shutdown_timeout).to eq(30)
      expect(config.logger).to eq(custom_logger)
      expect(config.enable_http2).to be(false)
      expect(config.dns_cache_ttl).to eq(600)
      expect(config.backpressure_strategy).to eq(:drop_oldest)
    end

    it "works without a block" do
      config = described_class.configure
      expect(config).to be_a(Sidekiq::AsyncHttp::Configuration)
      expect(config.max_connections).to eq(256) # default
    end
  end

  describe ".configuration" do
    after do
      described_class.reset_configuration!
    end

    it "returns a default configuration if not configured" do
      config = described_class.configuration

      expect(config).to be_a(Sidekiq::AsyncHttp::Configuration)
      expect(config.max_connections).to eq(256)
      expect(config.backpressure_strategy).to eq(:raise)
    end

    it "returns the configured configuration" do
      described_class.configure do |c|
        c.max_connections = 1024
      end

      config = described_class.configuration
      expect(config.max_connections).to eq(1024)
    end

    it "is frozen" do
      config = described_class.configuration
      expect(config).to be_frozen
    end
  end

  describe ".reset_configuration!" do
    it "resets to default configuration" do
      described_class.configure do |c|
        c.max_connections = 1024
      end

      expect(described_class.configuration.max_connections).to eq(1024)

      described_class.reset_configuration!

      expect(described_class.configuration.max_connections).to eq(256)
    end

    it "returns the new default configuration" do
      config = described_class.reset_configuration!

      expect(config).to be_a(Sidekiq::AsyncHttp::Configuration)
      expect(config.max_connections).to eq(256)
    end
  end
end
