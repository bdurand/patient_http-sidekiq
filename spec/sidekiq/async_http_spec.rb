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

    it "yields a Configuration instance" do
      expect { |b| described_class.configure(&b) }.to yield_with_args(Sidekiq::AsyncHttp::Configuration)
    end

    it "builds and stores a Configuration" do
      config = described_class.configure do |c|
        c.max_connections = 512
      end

      expect(config).to be_a(Sidekiq::AsyncHttp::Configuration)
      expect(config.max_connections).to eq(512)
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
      end

      expect(config.max_connections).to eq(512)
      expect(config.idle_connection_timeout).to eq(120)
      expect(config.default_request_timeout).to eq(60)
      expect(config.shutdown_timeout).to eq(30)
      expect(config.logger).to eq(custom_logger)
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
    end

    it "returns the configured configuration" do
      described_class.configure do |c|
        c.max_connections = 1024
      end

      config = described_class.configuration
      expect(config.max_connections).to eq(1024)
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

  describe ".processor" do
    after do
      described_class.reset!
    end

    it "returns nil when no processor has been created" do
      expect(described_class.processor).to be_nil
    end

    it "returns the processor instance when it exists" do
      described_class.start
      processor = described_class.processor

      expect(processor).to be_a(Sidekiq::AsyncHttp::Processor)
      expect(processor).to be_running
    end
  end

  describe ".metrics" do
    after do
      described_class.reset!
    end

    it "returns nil when no processor exists" do
      expect(described_class.metrics).to be_nil
    end

    it "returns the processor's metrics when processor exists" do
      described_class.start
      metrics = described_class.metrics

      expect(metrics).to be_a(Sidekiq::AsyncHttp::Metrics)
      expect(metrics).to eq(described_class.processor.metrics)
    end
  end

  describe ".running?" do
    after do
      described_class.reset!
    end

    it "returns false when processor is nil" do
      expect(described_class.running?).to be(false)
    end

    it "returns false when processor is stopped" do
      described_class.instance_variable_set(:@processor, Sidekiq::AsyncHttp::Processor.new)

      expect(described_class.running?).to be(false)
    end

    it "returns true when processor is running" do
      described_class.start

      expect(described_class.running?).to be(true)
    end
  end

  describe ".start" do
    after do
      described_class.reset!
      described_class.stop
    end

    it "creates and starts a new processor" do
      described_class.start
      described_class.processor.wait_for_running

      expect(described_class.processor).to be_a(Sidekiq::AsyncHttp::Processor)
      expect(described_class.processor).to be_running
    end

    it "uses the current configuration" do
      described_class.configure do |c|
        c.max_connections = 512
      end

      described_class.start

      expect(described_class.processor.config.max_connections).to eq(512)
    end

    it "returns early if already running" do
      described_class.start
      first_processor = described_class.processor

      described_class.start
      second_processor = described_class.processor

      expect(second_processor).to be(first_processor)
    end
  end

  describe ".quiet" do
    after do
      described_class.reset!
    end

    it "calls drain on the processor" do
      described_class.start
      processor = described_class.processor

      expect(processor).to receive(:drain).and_call_original

      described_class.quiet
    end

    it "marks processor as draining" do
      described_class.start
      described_class.quiet

      expect(described_class.processor).to be_draining
    end

    it "returns early if not running" do
      expect { described_class.quiet }.not_to raise_error
    end
  end

  describe ".stop" do
    after do
      described_class.reset!
    end

    it "stops the processor and sets it to nil" do
      described_class.start
      processor = described_class.processor

      expect(processor).to be_running

      described_class.stop

      expect(processor).to be_stopped
      expect(described_class.processor).to be_nil
    end

    it "uses default shutdown_timeout from configuration" do
      described_class.configure do |c|
        c.shutdown_timeout = 15
      end

      described_class.start
      processor = described_class.processor

      expect(processor).to receive(:stop).with(timeout: 15).and_call_original

      described_class.stop
    end

    it "accepts custom timeout parameter" do
      described_class.start
      processor = described_class.processor

      expect(processor).to receive(:stop).with(timeout: 5).and_call_original

      described_class.stop(timeout: 5)
    end

    it "returns early if not running" do
      expect { described_class.stop }.not_to raise_error
    end
  end

  describe "lifecycle integration" do
    # Don't use the global after hook for these tests - handle cleanup explicitly
    after do
      described_class.reset! if described_class.running?
    end

    it "supports full start -> quiet -> stop lifecycle" do
      described_class.reset_configuration!
      described_class.configure do |c|
        c.shutdown_timeout = 10
      end

      # Start
      described_class.start
      expect(described_class).to be_running
      expect(described_class.processor).to be_running

      # Quiet
      described_class.quiet
      expect(described_class).to be_draining
      expect(described_class.processor).to be_draining

      # Stop
      described_class.stop
      expect(described_class).to be_stopped
      expect(described_class.processor).to be_nil
    end

    it "can restart after stopping" do
      described_class.start
      first_processor = described_class.processor

      described_class.stop
      expect(described_class.processor).to be_nil

      described_class.start
      second_processor = described_class.processor

      expect(second_processor).to be_a(Sidekiq::AsyncHttp::Processor)
      expect(second_processor).not_to be(first_processor)
      expect(second_processor).to be_running
    end
  end

  describe "callbacks" do
    let(:response_data) do
      {
        "status" => 200,
        "headers" => {"Content-Type" => "application/json"},
        "body" => {"encoding" => "text", "value" => '{"message":"success"}'},
        "duration" => 0.123,
        "request_id" => "req-123",
        "url" => "https://api.example.com/users",
        "method" => "get",
        "protocol" => "HTTP/2"
      }
    end

    let(:error_data) do
      {
        "class_name" => "Timeout::Error",
        "message" => "Request timed out",
        "backtrace" => ["line 1", "line 2", "line 3"],
        "error_type" => "timeout",
        "duration" => 0.5,
        "request_id" => "req-456",
        "url" => "https://api.example.com/slow",
        "method" => "post"
      }
    end

    describe ".after_completion" do
      around do |example|
        callbacks = described_class.instance_variable_get(:@after_completion_callbacks)
        begin
          described_class.instance_variable_set(:@after_completion_callbacks, [])
          example.run
        ensure
          described_class.instance_variable_set(:@after_completion_callbacks, callbacks)
        end
      end

      it "registers a callback block" do
        block_called = false
        described_class.after_completion do |response|
          block_called = true
        end

        callbacks = described_class.instance_variable_get(:@after_completion_callbacks)
        expect(callbacks.size).to eq(1)
      end

      it "allows registering multiple callbacks" do
        described_class.after_completion { |response| }
        described_class.after_completion { |response| }
        described_class.after_completion { |response| }

        callbacks = described_class.instance_variable_get(:@after_completion_callbacks)
        expect(callbacks.size).to eq(3)
      end
    end

    describe ".after_error" do
      around do |example|
        callbacks = described_class.instance_variable_get(:@after_error_callbacks)
        begin
          described_class.instance_variable_set(:@after_error_callbacks, [])
          example.run
        ensure
          described_class.instance_variable_set(:@after_error_callbacks, callbacks)
        end
      end

      it "registers a callback block" do
        block_called = false
        described_class.after_error do |error|
          block_called = true
        end

        callbacks = described_class.instance_variable_get(:@after_error_callbacks)
        expect(callbacks.size).to eq(1)
      end

      it "allows registering multiple callbacks" do
        described_class.after_error { |error| }
        described_class.after_error { |error| }
        described_class.after_error { |error| }

        callbacks = described_class.instance_variable_get(:@after_error_callbacks)
        expect(callbacks.size).to eq(3)
      end
    end

    describe ".invoke_completion_callbacks" do
      after do
        described_class.instance_variable_set(:@after_completion_callbacks, [])
      end

      it "invokes all registered completion callbacks with a Response object" do
        responses = []

        described_class.after_completion do |response|
          responses << response
        end

        described_class.after_completion do |response|
          responses << response
        end

        described_class.invoke_completion_callbacks(response_data)

        expect(responses.size).to eq(2)
        expect(responses.first).to be_a(Sidekiq::AsyncHttp::Response)
        expect(responses.first.status).to eq(200)
        expect(responses.first.url).to eq("https://api.example.com/users")
        expect(responses.first.method).to eq(:get)
        expect(responses.first.request_id).to eq("req-123")
      end

      it "converts hash to Response object before invoking callbacks" do
        response_received = nil

        described_class.after_completion do |response|
          response_received = response
        end

        described_class.invoke_completion_callbacks(response_data)

        expect(response_received).to be_a(Sidekiq::AsyncHttp::Response)
        expect(response_received.status).to eq(200)
        expect(response_received.headers["Content-Type"]).to eq("application/json")
        expect(response_received.body).to eq('{"message":"success"}')
        expect(response_received.duration).to eq(0.123)
      end

      it "invokes callbacks in registration order" do
        call_order = []

        described_class.after_completion do |response|
          call_order << :first
        end

        described_class.after_completion do |response|
          call_order << :second
        end

        described_class.after_completion do |response|
          call_order << :third
        end

        described_class.invoke_completion_callbacks(response_data)

        expect(call_order).to eq([:first, :second, :third])
      end

      it "does nothing when no callbacks are registered" do
        expect do
          described_class.invoke_completion_callbacks(response_data)
        end.not_to raise_error
      end
    end

    describe ".invoke_error_callbacks" do
      after do
        described_class.instance_variable_set(:@after_error_callbacks, [])
      end

      it "invokes all registered error callbacks with an Error object" do
        errors = []

        described_class.after_error do |error|
          errors << error
        end

        described_class.after_error do |error|
          errors << error
        end

        described_class.invoke_error_callbacks(error_data)

        expect(errors.size).to eq(2)
        expect(errors.first).to be_a(Sidekiq::AsyncHttp::Error)
        expect(errors.first.class_name).to eq("Timeout::Error")
        expect(errors.first.message).to eq("Request timed out")
        expect(errors.first.error_type).to eq(:timeout)
        expect(errors.first.request_id).to eq("req-456")
      end

      it "converts hash to Error object before invoking callbacks" do
        error_received = nil

        described_class.after_error do |error|
          error_received = error
        end

        described_class.invoke_error_callbacks(error_data)

        expect(error_received).to be_a(Sidekiq::AsyncHttp::Error)
        expect(error_received.class_name).to eq("Timeout::Error")
        expect(error_received.message).to eq("Request timed out")
        expect(error_received.backtrace).to eq(["line 1", "line 2", "line 3"])
        expect(error_received.url).to eq("https://api.example.com/slow")
        expect(error_received.method).to eq(:post)
      end

      it "invokes callbacks in registration order" do
        call_order = []

        described_class.after_error do |error|
          call_order << :first
        end

        described_class.after_error do |error|
          call_order << :second
        end

        described_class.after_error do |error|
          call_order << :third
        end

        described_class.invoke_error_callbacks(error_data)

        expect(call_order).to eq([:first, :second, :third])
      end

      it "does nothing when no callbacks are registered" do
        expect do
          described_class.invoke_error_callbacks(error_data)
        end.not_to raise_error
      end
    end
  end
end
