# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Configuration do
  describe "#initialize" do
    context "with no arguments" do
      it "uses default values" do
        config = described_class.new

        expect(config.max_connections).to eq(256)
        expect(config.request_timeout).to eq(60)
        expect(config.shutdown_timeout).to eq(Sidekiq.default_configuration[:timeout] - 2)
        expect(config.logger).to eq(Sidekiq.logger)
        expect(config.raise_error_responses).to eq(false)
        expect(config.max_redirects).to eq(5)
        expect(config.connection_pool_size).to eq(100)
        expect(config.connection_timeout).to be_nil
        expect(config.proxy_url).to be_nil
        expect(config.retries).to eq(3)
      end
    end

    context "with custom values" do
      it "uses provided values" do
        custom_logger = Logger.new($stdout)
        config = described_class.new(
          max_connections: 512,
          request_timeout: 120,
          shutdown_timeout: 30,
          logger: custom_logger,
          raise_error_responses: true
        )

        expect(config.max_connections).to eq(512)
        expect(config.request_timeout).to eq(120)
        expect(config.shutdown_timeout).to eq(30)
        expect(config.logger).to eq(custom_logger)
        expect(config.raise_error_responses).to eq(true)
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

    context "with invalid request_timeout" do
      it "raises ArgumentError for zero" do
        expect { described_class.new(request_timeout: 0) }.to raise_error(
          ArgumentError,
          "request_timeout must be a positive number, got: 0"
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
          request_timeout: 15.25,
          shutdown_timeout: 20.75
        )
      end
    end

    context "with invalid max_redirects" do
      it "raises ArgumentError for negative value" do
        expect { described_class.new(max_redirects: -1) }.to raise_error(
          ArgumentError,
          "max_redirects must be a non-negative integer, got: -1"
        )
      end

      it "raises ArgumentError for non-integer" do
        expect { described_class.new(max_redirects: 5.5) }.to raise_error(
          ArgumentError,
          "max_redirects must be a non-negative integer, got: 5.5"
        )
      end

      it "raises ArgumentError for string" do
        expect { described_class.new(max_redirects: "5") }.to raise_error(
          ArgumentError,
          /max_redirects must be a non-negative integer/
        )
      end

      it "allows zero to disable redirects" do
        expect { described_class.new(max_redirects: 0) }.not_to raise_error
      end

      it "allows positive integers" do
        config = described_class.new(max_redirects: 10)
        expect(config.max_redirects).to eq(10)
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

    context "with invalid connection_pool_size" do
      it "raises ArgumentError for zero" do
        expect { described_class.new(connection_pool_size: 0) }.to raise_error(
          ArgumentError,
          "connection_pool_size must be a positive integer, got: 0"
        )
      end

      it "raises ArgumentError for negative" do
        expect { described_class.new(connection_pool_size: -1) }.to raise_error(
          ArgumentError,
          "connection_pool_size must be a positive integer, got: -1"
        )
      end

      it "raises ArgumentError for non-integer" do
        expect { described_class.new(connection_pool_size: 100.5) }.to raise_error(
          ArgumentError,
          "connection_pool_size must be a positive integer, got: 100.5"
        )
      end

      it "allows positive integers" do
        config = described_class.new(connection_pool_size: 50)
        expect(config.connection_pool_size).to eq(50)
      end
    end

    context "with invalid connection_timeout" do
      it "raises ArgumentError for zero" do
        expect { described_class.new(connection_timeout: 0) }.to raise_error(
          ArgumentError,
          "connection_timeout must be a positive number, got: 0"
        )
      end

      it "raises ArgumentError for negative" do
        expect { described_class.new(connection_timeout: -1) }.to raise_error(
          ArgumentError,
          "connection_timeout must be a positive number, got: -1"
        )
      end

      it "allows nil" do
        config = described_class.new(connection_timeout: nil)
        expect(config.connection_timeout).to be_nil
      end

      it "allows positive numbers" do
        config = described_class.new(connection_timeout: 30)
        expect(config.connection_timeout).to eq(30)
      end

      it "allows positive floats" do
        config = described_class.new(connection_timeout: 5.5)
        expect(config.connection_timeout).to eq(5.5)
      end
    end

    context "with invalid proxy_url" do
      it "raises ArgumentError for invalid URL" do
        expect { described_class.new(proxy_url: "not-a-url") }.to raise_error(
          ArgumentError,
          /proxy_url must be an HTTP or HTTPS URL/
        )
      end

      it "raises ArgumentError for FTP URL" do
        expect { described_class.new(proxy_url: "ftp://proxy.example.com") }.to raise_error(
          ArgumentError,
          /proxy_url must be an HTTP or HTTPS URL/
        )
      end

      it "allows nil" do
        config = described_class.new(proxy_url: nil)
        expect(config.proxy_url).to be_nil
      end

      it "allows HTTP URL" do
        config = described_class.new(proxy_url: "http://proxy.example.com:8080")
        expect(config.proxy_url).to eq("http://proxy.example.com:8080")
      end

      it "allows HTTPS URL" do
        config = described_class.new(proxy_url: "https://proxy.example.com:8080")
        expect(config.proxy_url).to eq("https://proxy.example.com:8080")
      end

      it "allows URL with authentication" do
        config = described_class.new(proxy_url: "http://user:pass@proxy.example.com:8080")
        expect(config.proxy_url).to eq("http://user:pass@proxy.example.com:8080")
      end
    end

    context "with invalid retries" do
      it "raises ArgumentError for negative" do
        expect { described_class.new(retries: -1) }.to raise_error(
          ArgumentError,
          "retries must be a non-negative integer, got: -1"
        )
      end

      it "raises ArgumentError for non-integer" do
        expect { described_class.new(retries: 3.5) }.to raise_error(
          ArgumentError,
          "retries must be a non-negative integer, got: 3.5"
        )
      end

      it "allows zero" do
        config = described_class.new(retries: 0)
        expect(config.retries).to eq(0)
      end

      it "allows positive integers" do
        config = described_class.new(retries: 5)
        expect(config.retries).to eq(5)
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
      it "defaults to Sidekiq.logger" do
        allow(Sidekiq).to receive(:logger).and_return(:sidekiq_logger)
        config = described_class.new

        expect(config.logger).to eq(:sidekiq_logger)
      end
    end
  end

  describe "#encryption" do
    it "defaults to identity (returns data unchanged)" do
      config = described_class.new
      data = {"key" => "value"}
      expect(config.encrypt(data)).to equal(data)
    end

    it "uses Sidekiq::EncryptedArgs when no encryptor is set and Sidekiq::EncryptedArgs is defined" do
      data = {"key" => "value"}
      stub_const("Sidekiq::EncryptedArgs", Class.new)
      allow(Sidekiq::EncryptedArgs).to receive(:encrypt).with("encrypted").and_return(data)
      config = described_class.new
      expect(config.encrypt("encrypted")).to eq(data)
    end

    it "sets encryptor via callable argument" do
      encryptor = ->(data) { data.merge("encrypted" => true) }
      config = described_class.new
      config.encryption(encryptor)

      expect(config.encryptor).to eq(encryptor)
      expect(config.encrypt({"key" => "value"})).to eq({"key" => "value", "encrypted" => true})
    end

    it "sets encryptor via block" do
      config = described_class.new
      config.encryption { |data| data.merge("encrypted" => true) }

      expect(config.encrypt({"key" => "value"})).to eq({"key" => "value", "encrypted" => true})
    end

    it "accepts any object that responds to #call" do
      encryptor = Object.new
      def encryptor.call(data)
        data.merge("encrypted" => true)
      end

      config = described_class.new
      config.encryption(encryptor)

      expect(config.encrypt({"key" => "value"})).to eq({"key" => "value", "encrypted" => true})
    end

    it "raises ArgumentError when callable does not respond to #call" do
      config = described_class.new
      expect { config.encryption("not_callable") }.to raise_error(ArgumentError, "encryption callable must respond to #call")
    end

    it "raises ArgumentError when both callable and block are provided" do
      config = described_class.new
      expect { config.encryption(->(_) {}) { |_| } }.to raise_error(ArgumentError, "encryption accepts either a callable argument or a block, not both")
    end

    it "resets to identity when called with no arguments" do
      config = described_class.new
      config.encryption { |data| data.merge("encrypted" => true) }
      config.encryption

      data = {"key" => "value"}
      expect(config.encrypt(data)).to equal(data)
    end
  end

  describe "#decryption" do
    it "defaults to identity (returns data unchanged)" do
      config = described_class.new
      data = {"key" => "value"}
      expect(config.decrypt(data)).to equal(data)
    end

    it "uses Sidekiq::EncryptedArgs when no decryptor is set and Sidekiq::EncryptedArgs is defined" do
      data = {"key" => "value"}
      stub_const("Sidekiq::EncryptedArgs", Class.new)
      allow(Sidekiq::EncryptedArgs).to receive(:decrypt).with("encrypted").and_return(data)
      config = described_class.new
      expect(config.decrypt("encrypted")).to eq(data)
    end

    it "sets decryptor via callable argument" do
      decryptor = ->(data) { data.merge("decrypted" => true) }
      config = described_class.new
      config.decryption(decryptor)

      expect(config.decryptor).to eq(decryptor)
      expect(config.decrypt({"key" => "value"})).to eq({"key" => "value", "decrypted" => true})
    end

    it "sets decryptor via block" do
      config = described_class.new
      config.decryption { |data| data.merge("decrypted" => true) }

      expect(config.decrypt({"key" => "value"})).to eq({"key" => "value", "decrypted" => true})
    end

    it "raises ArgumentError when callable does not respond to #call" do
      config = described_class.new
      expect { config.decryption("not_callable") }.to raise_error(ArgumentError, "decryption callable must respond to #call")
    end

    it "raises ArgumentError when both callable and block are provided" do
      config = described_class.new
      expect { config.decryption(->(_) {}) { |_| } }.to raise_error(ArgumentError, "decryption accepts either a callable argument or a block, not both")
    end

    it "resets to identity when called with no arguments" do
      config = described_class.new
      config.decryption { |data| data.merge("decrypted" => true) }
      config.decryption

      data = {"key" => "value"}
      expect(config.decrypt(data)).to equal(data)
    end
  end

  describe "#to_h" do
    it "returns hash with string keys" do
      custom_logger = Logger.new($stdout)
      config = described_class.new(
        max_connections: 512,
        request_timeout: 60,
        shutdown_timeout: 30,
        logger: custom_logger,
        connection_pool_size: 50,
        connection_timeout: 10,
        proxy_url: "http://proxy.example.com:8080",
        retries: 5
      )

      hash = config.to_h

      expect(hash).to be_a(Hash)
      expect(hash["max_connections"]).to eq(512)
      expect(hash["request_timeout"]).to eq(60)
      expect(hash["shutdown_timeout"]).to eq(30)
      expect(hash["logger"]).to eq(custom_logger)
      expect(hash["raise_error_responses"]).to eq(false)
      expect(hash["max_redirects"]).to eq(5)
      expect(hash["connection_pool_size"]).to eq(50)
      expect(hash["connection_timeout"]).to eq(10)
      expect(hash["proxy_url"]).to eq("http://proxy.example.com:8080")
      expect(hash["retries"]).to eq(5)
      expect(hash["encryptor"]).to eq(false)
      expect(hash["decryptor"]).to eq(false)
    end

    it "reports encryption and decryption as true when configured" do
      config = described_class.new
      config.encryption { |data| data }
      config.decryption { |data| data }

      hash = config.to_h

      expect(hash["encryptor"]).to eq(true)
      expect(hash["decryptor"]).to eq(true)
    end
  end
end
