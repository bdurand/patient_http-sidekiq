# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Response do
  describe "#initialize" do
    it "initializes with keyword arguments" do
      response = described_class.new(
        status: 200,
        headers: {"Content-Type" => "text/plain"},
        body: "Hello, World!",
        duration: 0.123,
        request_id: "abc123",
        url: "https://example.com",
        method: :get,
        protocol: "HTTP/1.1"
      )

      expect(response.status).to eq(200)
      expect(response.headers).to be_a(Sidekiq::AsyncHttp::HttpHeaders)
      expect(response.headers["Content-Type"]).to eq("text/plain")
      expect(response.body).to eq("Hello, World!")
      expect(response.duration).to eq(0.123)
      expect(response.request_id).to eq("abc123")
      expect(response.protocol).to eq("HTTP/1.1")
      expect(response.url).to eq("https://example.com")
      expect(response.method).to eq(:get)
    end

    it "handles empty headers" do
      response = described_class.new(
        status: 204,
        headers: {},
        body: "",
        duration: 0.05,
        request_id: "xyz789",
        url: "https://example.com/api",
        method: :delete,
        protocol: "HTTP/1.1"
      )

      expect(response.headers.to_h).to eq({})
    end

    it "handles nil body" do
      response = described_class.new(
        status: 204,
        headers: {"Content-Length" => "0"},
        body: nil,
        duration: 0.02,
        request_id: "no-body-456",
        url: "https://example.com/empty",
        method: :get,
        protocol: "HTTP/1.1"
      )

      expect(response.body).to be_nil
    end
  end

  describe "#success?" do
    it "returns true for 200 status" do
      response = described_class.new(status: 200, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.success?).to be true
    end

    it "returns true for 201 status" do
      response = described_class.new(status: 201, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :post, protocol: "HTTP/1.1")
      expect(response.success?).to be true
    end

    it "returns true for 299 status" do
      response = described_class.new(status: 299, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.success?).to be true
    end

    it "returns false for 199 status" do
      response = described_class.new(status: 199, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.success?).to be false
    end

    it "returns false for 300 status" do
      response = described_class.new(status: 300, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.success?).to be false
    end

    it "returns false for 400 status" do
      response = described_class.new(status: 400, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.success?).to be false
    end

    it "returns false for 500 status" do
      response = described_class.new(status: 500, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.success?).to be false
    end
  end

  describe "#redirect?" do
    it "returns true for 300 status" do
      response = described_class.new(status: 300, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.redirect?).to be true
    end

    it "returns true for 301 status" do
      response = described_class.new(status: 301, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.redirect?).to be true
    end

    it "returns true for 302 status" do
      response = described_class.new(status: 302, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.redirect?).to be true
    end

    it "returns true for 399 status" do
      response = described_class.new(status: 399, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.redirect?).to be true
    end

    it "returns false for 299 status" do
      response = described_class.new(status: 299, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.redirect?).to be false
    end

    it "returns false for 400 status" do
      response = described_class.new(status: 400, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.redirect?).to be false
    end
  end

  describe "#client_error?" do
    it "returns true for 400 status" do
      response = described_class.new(status: 400, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.client_error?).to be true
    end

    it "returns true for 404 status" do
      response = described_class.new(status: 404, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.client_error?).to be true
    end

    it "returns true for 499 status" do
      response = described_class.new(status: 499, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.client_error?).to be true
    end

    it "returns false for 399 status" do
      response = described_class.new(status: 399, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.client_error?).to be false
    end

    it "returns false for 500 status" do
      response = described_class.new(status: 500, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.client_error?).to be false
    end
  end

  describe "#server_error?" do
    it "returns true for 500 status" do
      response = described_class.new(status: 500, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.server_error?).to be true
    end

    it "returns true for 502 status" do
      response = described_class.new(status: 502, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.server_error?).to be true
    end

    it "returns true for 599 status" do
      response = described_class.new(status: 599, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.server_error?).to be true
    end

    it "returns false for 499 status" do
      response = described_class.new(status: 499, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.server_error?).to be false
    end

    it "returns false for 600 status" do
      response = described_class.new(status: 600, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.server_error?).to be false
    end
  end

  describe "#error?" do
    it "returns true for 400 status" do
      response = described_class.new(status: 400, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.error?).to be true
    end

    it "returns true for 404 status" do
      response = described_class.new(status: 404, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.error?).to be true
    end

    it "returns true for 500 status" do
      response = described_class.new(status: 500, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.error?).to be true
    end

    it "returns true for 599 status" do
      response = described_class.new(status: 599, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.error?).to be true
    end

    it "returns false for 200 status" do
      response = described_class.new(status: 200, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.error?).to be false
    end

    it "returns false for 300 status" do
      response = described_class.new(status: 300, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.error?).to be false
    end

    it "returns false for 399 status" do
      response = described_class.new(status: 399, headers: {}, body: "", duration: 0.1, request_id: "1", url: "http://test.com", method: :get, protocol: "HTTP/1.1")
      expect(response.error?).to be false
    end
  end

  describe "#json" do
    it "parses JSON body when Content-Type is application/json" do
      body = '{"name":"John","age":30}'
      response = described_class.new(
        status: 200,
        headers: {"Content-Type" => "application/json"},
        body: body,
        duration: 0.1,
        request_id: "1",
        url: "http://test.com",
        method: :get,
        protocol: "HTTP/1.1"
      )

      expect(response.json).to eq({"name" => "John", "age" => 30})
    end

    it "parses JSON body when Content-Type includes charset" do
      body = '{"success":true}'
      response = described_class.new(
        status: 200,
        headers: {"Content-Type" => "application/json; charset=utf-8"},
        body: body,
        duration: 0.1,
        request_id: "1",
        url: "http://test.com",
        method: :get,
        protocol: "HTTP/1.1"
      )

      expect(response.json).to eq({"success" => true})
    end

    it "raises error when Content-Type is not application/json" do
      response = described_class.new(
        status: 200,
        headers: {"Content-Type" => "text/plain"},
        body: "plain text",
        duration: 0.1,
        request_id: "1",
        url: "http://test.com",
        method: :get,
        protocol: "HTTP/1.1"
      )

      expect { response.json }.to raise_error(/Response Content-Type is not application\/json/)
    end

    it "raises error when Content-Type is missing" do
      response = described_class.new(
        status: 200,
        headers: {},
        body: '{"data":"value"}',
        duration: 0.1,
        request_id: "1",
        url: "http://test.com",
        method: :get,
        protocol: "HTTP/1.1"
      )

      expect { response.json }.to raise_error(/Response Content-Type is not application\/json/)
    end

    it "raises JSON::ParserError for invalid JSON" do
      response = described_class.new(
        status: 200,
        headers: {"Content-Type" => "application/json"},
        body: "not valid json",
        duration: 0.1,
        request_id: "1",
        url: "http://test.com",
        method: :get,
        protocol: "HTTP/1.1"
      )

      expect { response.json }.to raise_error(JSON::ParserError)
    end
  end

  describe "#to_h" do
    it "converts response to hash with string keys" do
      response = described_class.new(
        status: 201,
        headers: {"Content-Type" => "application/json", "X-Request-Id" => "abc"},
        body: '{"created":true}',
        duration: 0.456,
        request_id: "req-123",
        url: "https://api.example.com/items",
        method: :post,
        protocol: "HTTP/2"
      )

      hash = response.to_h

      expect(hash).to eq({
        "status" => 201,
        "headers" => {"content-type" => "application/json", "x-request-id" => "abc"},
        "body" => {"encoding" => "text", "value" => '{"created":true}'},
        "duration" => 0.456,
        "request_id" => "req-123",
        "protocol" => "HTTP/2",
        "url" => "https://api.example.com/items",
        "method" => "post"
      })
    end

    it "includes all attributes" do
      response = described_class.new(
        status: 200,
        headers: {},
        body: "",
        duration: 1.5,
        request_id: "xyz",
        url: "http://test.com",
        method: :get,
        protocol: "HTTP/1.1"
      )

      hash = response.to_h

      expect(hash.keys).to contain_exactly(
        "status", "headers", "body", "duration", "request_id", "protocol", "url", "method"
      )
    end

    it "handles nil body" do
      response = described_class.new(
        status: 204,
        headers: {},
        body: nil,
        duration: 0.2,
        request_id: "no-body",
        url: "http://test.com/nobody",
        method: :get,
        protocol: "HTTP/1.1"
      )

      hash = response.to_h

      expect(hash["body"]).to be_nil
    end
  end

  describe ".from_h" do
    it "reconstructs a response from a hash" do
      hash = {
        "status" => 200,
        "headers" => {"Content-Type" => "text/html"},
        "body" => {"encoding" => "text", "value" => "<html></html>"},
        "duration" => 0.25,
        "request_id" => "req-456",
        "protocol" => "HTTP/1.1",
        "url" => "https://example.com/page",
        "method" => "get"
      }

      response = described_class.from_h(hash)

      expect(response.status).to eq(200)
      expect(response.headers["Content-Type"]).to eq("text/html")
      expect(response.body).to eq("<html></html>")
      expect(response.duration).to eq(0.25)
      expect(response.request_id).to eq("req-456")
      expect(response.protocol).to eq("HTTP/1.1")
      expect(response.url).to eq("https://example.com/page")
      expect(response.method).to eq(:get)
    end

    it "round-trips through to_h" do
      original = described_class.new(
        status: 404,
        headers: {"X-Custom" => "value"},
        body: "Not Found",
        duration: 0.123,
        request_id: "original-id",
        url: "https://api.test.com/missing",
        method: :delete,
        protocol: "HTTP/1.1"
      )

      hash = original.to_h
      reconstructed = described_class.from_h(hash)

      expect(reconstructed.status).to eq(original.status)
      expect(reconstructed.headers.to_h).to eq(original.headers.to_h)
      expect(reconstructed.body).to eq(original.body)
      expect(reconstructed.duration).to eq(original.duration)
      expect(reconstructed.request_id).to eq(original.request_id)
      expect(reconstructed.protocol).to eq(original.protocol)
      expect(reconstructed.url).to eq(original.url)
      expect(reconstructed.method).to eq(original.method)
    end

    it "supports a nil body" do
      hash = {
        "status" => 204,
        "headers" => {},
        "body" => nil,
        "duration" => 0.05,
        "request_id" => "req-789",
        "protocol" => "HTTP/1.1",
        "url" => "https://example.com/empty",
        "method" => "get"
      }

      response = described_class.from_h(hash)

      expect(response.status).to eq(204)
      expect(response.body).to be_nil
    end
  end
end
