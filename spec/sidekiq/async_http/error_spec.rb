# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Error do
  describe "ERROR_TYPES" do
    it "defines valid error types" do
      expect(described_class::ERROR_TYPES).to eq(%i[timeout connection ssl protocol response_too_large unknown])
    end

    it "is frozen" do
      expect(described_class::ERROR_TYPES).to be_frozen
    end
  end

  describe ".from_exception" do
    let(:request_id) { "req_123" }
    let(:url) { "https://example.com" }

    context "with Async::TimeoutError" do
      it "classifies as :timeout" do
        exception = Async::TimeoutError.new("Request timeout")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url, method: :get)

        expect(error.class_name).to eq("Async::TimeoutError")
        expect(error.message).to eq("Request timeout")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:timeout)
        expect(error.duration).to eq(1.0)
      end
    end

    context "with OpenSSL::SSL::SSLError" do
      it "classifies as :ssl" do
        exception = OpenSSL::SSL::SSLError.new("SSL error")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url, method: :get)

        expect(error.class_name).to eq("OpenSSL::SSL::SSLError")
        expect(error.message).to eq("SSL error")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:ssl)
      end
    end

    context "with connection errors" do
      it "classifies Errno::ECONNREFUSED as :connection" do
        exception = Errno::ECONNREFUSED.new("Connection refused")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url, method: :get)

        expect(error.class_name).to eq("Errno::ECONNREFUSED")
        expect(error.message).to eq("Connection refused - Connection refused")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:connection)
      end

      it "classifies Errno::ECONNRESET as :connection" do
        exception = Errno::ECONNRESET.new("Connection reset")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url, method: :get)

        expect(error.class_name).to eq("Errno::ECONNRESET")
        expect(error.error_type).to eq(:connection)
      end

      it "classifies Errno::EHOSTUNREACH as :connection" do
        exception = Errno::EHOSTUNREACH.new("Host unreachable")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url, method: :get)

        expect(error.class_name).to eq("Errno::EHOSTUNREACH")
        expect(error.error_type).to eq(:connection)
      end
    end

    context "with Async::HTTP::Protocol::Error" do
      it "classifies as :protocol" do
        # Create a mock exception with the right class name
        exception = StandardError.new("Protocol error")
        allow(exception.class).to receive(:name).and_return("Async::HTTP::Protocol::Error")

        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url, method: :get)

        expect(error.class_name).to eq("Async::HTTP::Protocol::Error")
        expect(error.message).to eq("Protocol error")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:protocol)
      end
    end

    context "with ResponseTooLargeError" do
      it "classifies as :response_too_large" do
        exception = Sidekiq::AsyncHttp::ResponseTooLargeError.new("Response too large")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url, method: :get)

        expect(error.class_name).to eq("Sidekiq::AsyncHttp::ResponseTooLargeError")
        expect(error.message).to eq("Response too large")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:response_too_large)
      end
    end

    context "with unknown exception" do
      it "classifies as :unknown" do
        exception = StandardError.new("Unknown error")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url, method: :get)

        expect(error.class_name).to eq("StandardError")
        expect(error.message).to eq("Unknown error")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:unknown)
      end
    end

    context "with backtrace" do
      it "captures the backtrace" do
        exception = StandardError.new("Error with backtrace")
        exception.set_backtrace(["line 1", "line 2", "line 3"])
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url, method: :get)

        expect(error.backtrace).to eq(["line 1", "line 2", "line 3"])
      end
    end

    context "without backtrace" do
      it "uses empty array" do
        exception = StandardError.new("Error without backtrace")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url, method: :get)

        expect(error.backtrace).to eq([])
      end
    end
  end

  describe "#to_h" do
    let(:error) do
      described_class.new(
        class_name: "StandardError",
        message: "Test error",
        backtrace: ["line 1", "line 2"],
        request_id: "req_123",
        error_type: :timeout,
        duration: 2.5,
        url: "https://example.com",
        method: :get
      )
    end

    it "returns hash with string keys" do
      hash = error.to_h

      expect(hash).to eq({
        "class_name" => "StandardError",
        "message" => "Test error",
        "backtrace" => ["line 1", "line 2"],
        "request_id" => "req_123",
        "error_type" => "timeout",
        "duration" => 2.5,
        "url" => "https://example.com",
        "method" => "get"
      })
    end

    it "converts error_type to string" do
      expect(error.to_h["error_type"]).to be_a(String)
      expect(error.to_h["error_type"]).to eq("timeout")
    end
  end

  describe ".from_h" do
    let(:hash) do
      {
        "class_name" => "StandardError",
        "message" => "Test error",
        "backtrace" => ["line 1", "line 2"],
        "request_id" => "req_123",
        "error_type" => "timeout",
        "duration" => 2.5,
        "url" => "https://example.com",
        "method" => "get"
      }
    end

    it "reconstructs error from hash" do
      error = described_class.from_h(hash)

      expect(error.class_name).to eq("StandardError")
      expect(error.message).to eq("Test error")
      expect(error.backtrace).to eq(["line 1", "line 2"])
      expect(error.request_id).to eq("req_123")
      expect(error.error_type).to eq(:timeout)
      expect(error.duration).to eq(2.5)
      expect(error.url).to eq("https://example.com")
      expect(error.method).to eq(:get)
    end

    it "converts error_type string to symbol" do
      error = described_class.from_h(hash)
      expect(error.error_type).to be_a(Symbol)
    end
  end

  describe "round-trip serialization" do
    let(:original_error) do
      described_class.new(
        class_name: "ArgumentError",
        message: "Invalid argument",
        backtrace: ["foo.rb:10", "bar.rb:20"],
        request_id: "req_456",
        error_type: :ssl,
        duration: 1.0,
        url: "https://example.com",
        method: :get
      )
    end

    it "preserves all data through to_h and from_h" do
      hash = original_error.to_h
      restored_error = described_class.from_h(hash)

      expect(restored_error.class_name).to eq(original_error.class_name)
      expect(restored_error.message).to eq(original_error.message)
      expect(restored_error.backtrace).to eq(original_error.backtrace)
      expect(restored_error.request_id).to eq(original_error.request_id)
      expect(restored_error.error_type).to eq(original_error.error_type)
      expect(restored_error.duration).to eq(original_error.duration)
      expect(restored_error.url).to eq(original_error.url)
      expect(restored_error.method).to eq(original_error.method)
    end
  end

  describe "#error_class" do
    context "when class exists" do
      it "returns the exception class constant" do
        error = described_class.new(
          class_name: "StandardError",
          message: "Test",
          backtrace: [],
          request_id: "req_123",
          error_type: :unknown,
          duration: 1.0,
          url: "https://example.com",
          method: :get
        )

        expect(error.error_class).to eq(StandardError)
      end

      it "works with nested classes" do
        error = described_class.new(
          class_name: "OpenSSL::SSL::SSLError",
          message: "Test",
          backtrace: [],
          request_id: "req_123",
          error_type: :ssl,
          duration: 1.0,
          url: "https://example.com",
          method: :get
        )

        expect(error.error_class).to eq(OpenSSL::SSL::SSLError)
      end
    end
  end
end
