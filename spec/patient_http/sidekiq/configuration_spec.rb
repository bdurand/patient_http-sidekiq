# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::Configuration do
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

    context "with on_retries_exhausted" do
      it "accepts a callable object" do
        handler = ->(error) { error }
        config = described_class.new(on_retries_exhausted: handler)
        expect(config.on_retries_exhausted).to eq(handler)
      end

      it "accepts nil" do
        config = described_class.new(on_retries_exhausted: nil)
        expect(config.on_retries_exhausted).to be_nil
      end

      it "raises ArgumentError for non-callable value" do
        expect { described_class.new(on_retries_exhausted: "not_callable") }.to raise_error(
          ArgumentError,
          "on_retries_exhausted must respond to #call, got: String"
        )
      end

      it "accepts a block via the setter" do
        config = described_class.new
        config.on_retries_exhausted { |error| error }
        expect(config.on_retries_exhausted).to be_a(Proc)
      end
    end
  end

  describe "#direct_execution" do
    it "defaults to true" do
      config = described_class.new

      expect(config.direct_execution).to be(true)
      expect(config.direct_execution?).to be(true)
    end

    it "can be set with the initializer" do
      config = described_class.new(direct_execution: false)

      expect(config.direct_execution?).to be(false)
    end

    it "coerces the value to a boolean" do
      config = described_class.new

      config.direct_execution = nil
      expect(config.direct_execution).to be(false)

      config.direct_execution = "truthy"
      expect(config.direct_execution).to be(true)
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
      expect(hash["direct_execution"]).to eq(true)
    end
  end

  describe "Redis pool options" do
    it "defaults redis_pool_size to nil and redis_pool_timeout to 5" do
      config = described_class.new
      expect(config.redis_pool_size).to be_nil
      expect(config.redis_pool_timeout).to eq(5)
    end

    it "accepts explicit values" do
      config = described_class.new(redis_pool_size: 20, redis_pool_timeout: 2.5)
      expect(config.redis_pool_size).to eq(20)
      expect(config.redis_pool_timeout).to eq(2.5)
    end

    it "validates the values" do
      expect { described_class.new(redis_pool_size: 0) }.to raise_error(ArgumentError, /redis_pool_size/)
      expect { described_class.new(redis_pool_timeout: 0) }.to raise_error(ArgumentError, /redis_pool_timeout/)
    end
  end

  describe "stats_flush_interval" do
    it "defaults to 5 and accepts 0 for synchronous flushing" do
      expect(described_class.new.stats_flush_interval).to eq(5)
      expect(described_class.new(stats_flush_interval: 0).stats_flush_interval).to eq(0)
    end

    it "rejects negative values" do
      expect { described_class.new(stats_flush_interval: -1) }.to raise_error(ArgumentError, /stats_flush_interval/)
    end
  end

  describe "#processor" do
    it "always includes a default profile" do
      config = described_class.new
      expect(config.processor_profiles).to eq(default: {})
    end

    it "declares named profiles with option overrides" do
      config = described_class.new
      config.processor(:llm, max_connections: 200, request_timeout: 120)
      config.processor(:webhooks, max_connections: 64)

      expect(config.processor_profiles.keys).to eq([:default, :llm, :webhooks])
      expect(config.processor(:llm)).to eq(max_connections: 200, request_timeout: 120)
    end

    it "rejects invalid profile options" do
      config = described_class.new
      expect { config.processor(:bad, max_connections: 0) }.to raise_error(ArgumentError, /Invalid processor profile options/)
      expect { config.processor(:bad, no_such_option: 1) }.to raise_error(ArgumentError, /Invalid processor profile options/)
    end

    it "rejects an empty name" do
      config = described_class.new
      expect { config.processor("", max_connections: 1) }.to raise_error(ArgumentError, /processor name cannot be empty/)
    end

    it "records in-flight request details by default and can turn them off" do
      config = described_class.new
      expect(config.inflight_details?).to be(true)

      config.inflight_details = false
      expect(config.inflight_details?).to be(false)
      expect(described_class.new(inflight_details: false).inflight_details?).to be(false)
    end

    it "takes a URL sanitizer as a block or a callable" do
      config = described_class.new
      expect(config.inflight_url_sanitizer).to be_nil

      config.inflight_url_sanitizer { |url| url.upcase }
      expect(config.inflight_url_sanitizer.call("https://example.com")).to eq("HTTPS://EXAMPLE.COM")

      config.inflight_url_sanitizer = ->(url) { url.reverse }
      expect(config.inflight_url_sanitizer.call("ab")).to eq("ba")
    end

    it "rejects a URL sanitizer that cannot be called" do
      expect { described_class.new.inflight_url_sanitizer = "nope" }.to raise_error(
        ArgumentError, /inflight_url_sanitizer must respond to #call/
      )
    end

    it "reports whether more than one profile is declared" do
      config = described_class.new
      expect(config.multiple_processors?).to be(false)

      config.processor(:llm, max_connections: 10)
      expect(config.multiple_processors?).to be(true)
    end
  end

  describe "#processor_config" do
    it "returns the configuration itself for the default profile" do
      config = described_class.new
      expect(config.processor_config(:default)).to be(config)
    end

    it "applies profile overrides on top of the base options" do
      config = described_class.new(max_connections: 100, request_timeout: 30)
      config.processor(:llm, max_connections: 200)

      llm_config = config.processor_config(:llm)
      expect(llm_config.max_connections).to eq(200)
      expect(llm_config.request_timeout).to eq(30)
    end

    it "shares secrets and preprocessors with the base configuration" do
      config = described_class.new
      config.register_secret(:token, "secret-value")
      config.processor(:llm, max_connections: 5)

      llm_config = config.processor_config(:llm)
      expect(llm_config.secret_manager.resolve_headers("authorization" => PatientHttp.secret(:token))).to eq(
        "authorization" => "secret-value"
      )
    end

    it "raises for an unknown profile" do
      config = described_class.new
      expect { config.processor_config(:nope) }.to raise_error(ArgumentError, /Unknown processor profile/)
    end
  end
end
