# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::RequestError do
  describe ".from_exception" do
    let(:request_id) { "req_123" }
    let(:url) { "https://example.com" }

    context "with Async::TimeoutError" do
      it "classifies as :timeout" do
        exception = Async::TimeoutError.new("Request timeout")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(Async::TimeoutError)
        expect(error.message).to eq("Request timeout")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:timeout)
        expect(error.duration).to eq(1.0)
      end
    end

    context "with OpenSSL::SSL::SSLError" do
      it "classifies as :ssl" do
        exception = OpenSSL::SSL::SSLError.new("SSL error")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(OpenSSL::SSL::SSLError)
        expect(error.message).to eq("SSL error")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:ssl)
      end
    end

    context "with connection errors" do
      it "classifies Errno::ECONNREFUSED as :connection" do
        exception = Errno::ECONNREFUSED.new("Connection refused")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(Errno::ECONNREFUSED)
        expect(error.message).to eq("Connection refused - Connection refused")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:connection)
      end

      it "classifies Errno::ECONNRESET as :connection" do
        exception = Errno::ECONNRESET.new("Connection reset")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(Errno::ECONNRESET)
        expect(error.error_type).to eq(:connection)
      end

      it "classifies Errno::EHOSTUNREACH as :connection" do
        exception = Errno::EHOSTUNREACH.new("Host unreachable")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(Errno::EHOSTUNREACH)
        expect(error.error_type).to eq(:connection)
      end

      it "classifies Errno::EPIPE as :connection" do
        exception = Errno::EPIPE.new("Broken pipe")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(Errno::EPIPE)
        expect(error.error_type).to eq(:connection)
      end

      it "classifies SocketError as :connection" do
        exception = SocketError.new("Socket error")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(SocketError)
        expect(error.error_type).to eq(:connection)
      end

      it "classifies IOError as :connection" do
        exception = IOError.new("IO error")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(IOError)
        expect(error.error_type).to eq(:connection)
      end
    end

    context "with ResponseTooLargeError" do
      it "classifies as :response_too_large" do
        exception = Sidekiq::AsyncHttp::ResponseTooLargeError.new("Response too large")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(Sidekiq::AsyncHttp::ResponseTooLargeError)
        expect(error.message).to eq("Response too large")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:response_too_large)
      end
    end

    context "with unknown exception" do
      it "classifies as :unknown" do
        exception = StandardError.new("Unknown error")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(StandardError)
        expect(error.message).to eq("Unknown error")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:unknown)
      end
    end

    context "with backtrace" do
      it "captures the backtrace" do
        exception = StandardError.new("Error with backtrace")
        exception.set_backtrace(["line 1", "line 2", "line 3"])
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.backtrace).to eq(["line 1", "line 2", "line 3"])
      end
    end

    context "without backtrace" do
      it "uses empty array" do
        exception = StandardError.new("Error without backtrace")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)
        expect(error.backtrace).to eq([])
      end
    end

    context "with callback_args" do
      it "includes callback_args in the error" do
        exception = StandardError.new("Test error")
        callback_args = {"user_id" => 123, "action" => "fetch"}
        error = described_class.from_exception(
          exception,
          request_id: request_id,
          duration: 1.0,
          url: url,
          http_method: :get,
          callback_args: callback_args
        )

        expect(error.callback_args).to be_a(Sidekiq::AsyncHttp::CallbackArgs)
        expect(error.callback_args[:user_id]).to eq(123)
        expect(error.callback_args[:action]).to eq("fetch")
      end

      it "defaults callback_args to empty when not provided" do
        exception = StandardError.new("Test error")
        error = described_class.from_exception(
          exception,
          request_id: request_id,
          duration: 1.0,
          url: url,
          http_method: :get
        )

        expect(error.callback_args).to be_a(Sidekiq::AsyncHttp::CallbackArgs)
        expect(error.callback_args).to be_empty
      end
    end
  end

  describe ".error_type" do
    it "classifies errors correctly" do
      expect(described_class.error_type(Async::TimeoutError.new)).to eq(:timeout)
      expect(described_class.error_type(Sidekiq::AsyncHttp::ResponseTooLargeError.new)).to eq(:response_too_large)
      expect(described_class.error_type(OpenSSL::SSL::SSLError.new)).to eq(:ssl)
      expect(described_class.error_type(Errno::ECONNREFUSED.new)).to eq(:connection)
      expect(described_class.error_type(Errno::ECONNRESET.new)).to eq(:connection)
      expect(described_class.error_type(StandardError.new)).to eq(:unknown)
    end
  end

  describe "#as_json" do
    let(:error) do
      described_class.new(
        class_name: "StandardError",
        message: "Test error",
        backtrace: ["line 1", "line 2"],
        request_id: "req_123",
        error_type: :timeout,
        duration: 2.5,
        url: "https://example.com",
        http_method: :get,
        callback_args: {"user_id" => 123}
      )
    end

    it "returns hash with string keys" do
      hash = error.as_json

      expect(hash).to eq({
        "class_name" => "StandardError",
        "message" => "Test error",
        "backtrace" => ["line 1", "line 2"],
        "request_id" => "req_123",
        "error_type" => "timeout",
        "duration" => 2.5,
        "url" => "https://example.com",
        "http_method" => "get",
        "callback_args" => {"user_id" => 123}
      })
    end

    it "converts error_type to string" do
      expect(error.as_json["error_type"]).to be_a(String)
      expect(error.as_json["error_type"]).to eq("timeout")
    end
  end

  describe ".load" do
    let(:hash) do
      {
        "class_name" => "StandardError",
        "message" => "Test error",
        "backtrace" => ["line 1", "line 2"],
        "request_id" => "req_123",
        "error_type" => "timeout",
        "duration" => 2.5,
        "url" => "https://example.com",
        "http_method" => "get",
        "callback_args" => {"user_id" => 123}
      }
    end

    it "reconstructs error from hash" do
      error = described_class.load(hash)

      expect(error.error_class).to eq(StandardError)
      expect(error.message).to eq("Test error")
      expect(error.backtrace).to eq(["line 1", "line 2"])
      expect(error.request_id).to eq("req_123")
      expect(error.error_type).to eq(:timeout)
      expect(error.duration).to eq(2.5)
      expect(error.url).to eq("https://example.com")
      expect(error.http_method).to eq(:get)
      expect(error.callback_args[:user_id]).to eq(123)
    end

    it "converts error_type string to symbol" do
      error = described_class.load(hash)
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
        http_method: :get,
        callback_args: {"action" => "fetch", "count" => 5}
      )
    end

    it "preserves all data through as_json and load" do
      hash = original_error.as_json
      restored_error = described_class.load(hash)

      expect(restored_error.error_class).to eq(original_error.error_class)
      expect(restored_error.message).to eq(original_error.message)
      expect(restored_error.backtrace).to eq(original_error.backtrace)
      expect(restored_error.request_id).to eq(original_error.request_id)
      expect(restored_error.error_type).to eq(original_error.error_type)
      expect(restored_error.duration).to eq(original_error.duration)
      expect(restored_error.url).to eq(original_error.url)
      expect(restored_error.http_method).to eq(original_error.http_method)
      expect(restored_error.callback_args.to_h).to eq(original_error.callback_args.to_h)
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
          http_method: :get
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
          http_method: :get
        )

        expect(error.error_class).to eq(OpenSSL::SSL::SSLError)
      end
    end
  end
end

RSpec.describe Sidekiq::AsyncHttp::ClientError do
  describe "factory pattern" do
    it "returns ClientError for 4xx responses" do
      response = Sidekiq::AsyncHttp::Response.new(
        status: 404,
        headers: {"Content-Type" => "text/plain"},
        body: "Not Found",
        duration: 0.1,
        request_id: "test-request",
        url: "https://example.com",
        http_method: :get
      )

      error = Sidekiq::AsyncHttp::HttpError.new(response)

      expect(error).to be_a(Sidekiq::AsyncHttp::ClientError)
      expect(error).to be_a(Sidekiq::AsyncHttp::HttpError)
      expect(error.status).to eq(404)
      expect(error.message).to eq("HTTP 404 response from GET https://example.com")
    end

    it "inherits all HttpError behavior" do
      response = Sidekiq::AsyncHttp::Response.new(
        status: 400,
        headers: {"Content-Type" => "application/json"},
        body: '{"error":"Bad Request"}',
        duration: 0.05,
        request_id: "test-400",
        url: "https://api.example.com/endpoint",
        http_method: :post
      )

      error = Sidekiq::AsyncHttp::HttpError.new(response)

      expect(error.status).to eq(400)
      expect(error.url).to eq("https://api.example.com/endpoint")
      expect(error.http_method).to eq(:post)
      expect(error.duration).to eq(0.05)
      expect(error.request_id).to eq("test-400")
      expect(error.response).to eq(response)
    end
  end

  describe "serialization" do
    it "round-trips through JSON as ClientError" do
      response = Sidekiq::AsyncHttp::Response.new(
        status: 403,
        headers: {"Content-Type" => "text/plain"},
        body: "Forbidden",
        duration: 0.2,
        request_id: "test-403",
        url: "https://example.com/protected",
        http_method: :get,
        callback_args: {"user_id" => 123}
      )

      original_error = Sidekiq::AsyncHttp::HttpError.new(response)

      hash = original_error.as_json
      restored_error = Sidekiq::AsyncHttp::HttpError.load(hash)

      expect(restored_error).to be_a(Sidekiq::AsyncHttp::ClientError)
      expect(restored_error.status).to eq(original_error.status)
      expect(restored_error.url).to eq(original_error.url)
      expect(restored_error.http_method).to eq(original_error.http_method)
      expect(restored_error.duration).to eq(original_error.duration)
      expect(restored_error.request_id).to eq(original_error.request_id)
      expect(restored_error.message).to eq(original_error.message)
      expect(restored_error.response.body).to eq(original_error.response.body)
      expect(restored_error.response.headers.to_h).to eq(original_error.response.headers.to_h)
      expect(restored_error.callback_args.to_h).to eq(original_error.callback_args.to_h)
    end
  end
end

RSpec.describe Sidekiq::AsyncHttp::ServerError do
  describe "factory pattern" do
    it "returns ServerError for 5xx responses" do
      response = Sidekiq::AsyncHttp::Response.new(
        status: 500,
        headers: {"Content-Type" => "text/plain"},
        body: "Internal Server Error",
        duration: 0.3,
        request_id: "test-500",
        url: "https://example.com",
        http_method: :post
      )

      error = Sidekiq::AsyncHttp::HttpError.new(response)

      expect(error).to be_a(Sidekiq::AsyncHttp::ServerError)
      expect(error).to be_a(Sidekiq::AsyncHttp::HttpError)
      expect(error.status).to eq(500)
      expect(error.message).to eq("HTTP 500 response from POST https://example.com")
    end

    it "returns ServerError for 503 Service Unavailable" do
      response = Sidekiq::AsyncHttp::Response.new(
        status: 503,
        headers: {"Content-Type" => "text/plain"},
        body: "Service Unavailable",
        duration: 0.1,
        request_id: "test-503",
        url: "https://api.example.com",
        http_method: :get
      )

      error = Sidekiq::AsyncHttp::HttpError.new(response)

      expect(error).to be_a(Sidekiq::AsyncHttp::ServerError)
      expect(error.status).to eq(503)
    end

    it "inherits all HttpError behavior" do
      response = Sidekiq::AsyncHttp::Response.new(
        status: 502,
        headers: {"Content-Type" => "application/json"},
        body: '{"error":"Bad Gateway"}',
        duration: 0.15,
        request_id: "test-502",
        url: "https://api.example.com/endpoint",
        http_method: :put
      )

      error = Sidekiq::AsyncHttp::HttpError.new(response)

      expect(error.status).to eq(502)
      expect(error.url).to eq("https://api.example.com/endpoint")
      expect(error.http_method).to eq(:put)
      expect(error.duration).to eq(0.15)
      expect(error.request_id).to eq("test-502")
      expect(error.response).to eq(response)
    end
  end

  describe "serialization" do
    it "round-trips through JSON as ServerError" do
      response = Sidekiq::AsyncHttp::Response.new(
        status: 504,
        headers: {"Content-Type" => "text/plain"},
        body: "Gateway Timeout",
        duration: 30.0,
        request_id: "test-504",
        url: "https://slow.example.com/api",
        http_method: :post,
        callback_args: {"request_id" => "abc123"}
      )

      original_error = Sidekiq::AsyncHttp::HttpError.new(response)

      hash = original_error.as_json
      restored_error = Sidekiq::AsyncHttp::HttpError.load(hash)

      expect(restored_error).to be_a(Sidekiq::AsyncHttp::ServerError)
      expect(restored_error.status).to eq(original_error.status)
      expect(restored_error.url).to eq(original_error.url)
      expect(restored_error.http_method).to eq(original_error.http_method)
      expect(restored_error.duration).to eq(original_error.duration)
      expect(restored_error.request_id).to eq(original_error.request_id)
      expect(restored_error.message).to eq(original_error.message)
      expect(restored_error.response.body).to eq(original_error.response.body)
      expect(restored_error.response.headers.to_h).to eq(original_error.response.headers.to_h)
      expect(restored_error.callback_args.to_h).to eq(original_error.callback_args.to_h)
    end
  end
end
