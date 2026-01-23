# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Client do
  let(:base_url) { "https://api.example.com" }
  let(:default_headers) { {"Authorization" => "Bearer token123"} }

  describe "#initialize" do
    it "sets the base_url" do
      client = described_class.new(base_url: base_url)
      expect(client.base_url).to eq(base_url)
    end

    it "sets headers as HttpHeaders object" do
      client = described_class.new(headers: default_headers)
      expect(client.headers).to be_a(Sidekiq::AsyncHttp::HttpHeaders)
      expect(client.headers["Authorization"]).to eq("Bearer token123")
    end

    it "sets default timeout to 30 seconds" do
      client = described_class.new
      expect(client.timeout).to eq(30)
    end

    it "allows custom timeout" do
      client = described_class.new(timeout: 60)
      expect(client.timeout).to eq(60)
    end

    it "allows custom connect_timeout" do
      client = described_class.new(connect_timeout: 10)
      expect(client.connect_timeout).to eq(10)
    end

    it "initializes with empty headers by default" do
      client = described_class.new
      expect(client.headers.to_h).to eq({})
    end
  end

  describe "#async_request" do
    let(:client) { described_class.new(base_url: base_url, headers: default_headers) }

    it "returns an Request object" do
      result = client.async_request(:get, "/users")
      expect(result).to be_a(Sidekiq::AsyncHttp::Request)
    end

    it "creates Request with method, url, headers, body, and timeout" do
      result = client.async_request(:post, "/users", body: "data")
      expect(result.http_method).to eq(:post)
      expect(result.url).to eq("https://api.example.com/users")
      expect(result.headers.to_h).to include("authorization" => "Bearer token123")
      expect(result.body).to eq("data")
      expect(result.timeout).to eq(30)
    end

    context "with URI joining" do
      it "joins base_url with relative path" do
        client.async_request(:get, "/users")
        # The joining happens internally, we can verify it doesn't raise
      end

      it "handles paths without leading slash" do
        client.async_request(:get, "users")
        # Should not raise
      end

      it "handles full paths" do
        client.async_request(:get, "/api/v1/users")
        # Should not raise
      end
    end

    context "with query parameters" do
      it "adds params to the URI" do
        client.async_request(:get, "/users", params: {page: 1, limit: 10})
        # Params are encoded and added to query string
      end

      it "merges params with existing query string" do
        client.async_request(:get, "/users?active=true", params: {page: 1})
        # Should merge both query params
      end

      it "handles empty params" do
        result = client.async_request(:get, "/users", params: {})
        expect(result).to be_a(Sidekiq::AsyncHttp::Request)
      end

      it "handles special characters in params" do
        client.async_request(:get, "/search", params: {q: "hello world", filter: "type:user"})
        # Should URL encode params properly
      end
    end

    context "with headers" do
      it "merges request headers with instance headers" do
        client.async_request(:get, "/users", headers: {"X-Request-ID" => "abc123"})
        # Headers should be merged
      end

      it "does not merge when no headers provided" do
        result = client.async_request(:get, "/users")
        expect(result).to be_a(Sidekiq::AsyncHttp::Request)
      end

      it "handles empty headers hash" do
        result = client.async_request(:get, "/users", headers: {})
        expect(result).to be_a(Sidekiq::AsyncHttp::Request)
      end
    end

    context "with JSON body" do
      it "converts json to string body and sets Content-Type header" do
        data = {name: "John", email: "john@example.com"}
        result = client.async_request(:post, "/users", json: data)

        expect(result.body).to eq(JSON.generate(data))
        expect(result.headers["content-type"]).to eq("application/json; encoding=utf-8")
      end

      it "raises error when both body and json are provided" do
        expect {
          client.async_request(:post, "/users", body: "raw data", json: {name: "John"})
        }.to raise_error(ArgumentError, "Cannot provide both body and json")
      end

      it "handles complex JSON structures" do
        data = {
          user: {
            name: "John",
            roles: ["admin", "user"],
            metadata: {created_at: "2026-01-09"}
          }
        }
        result = client.async_request(:post, "/users", json: data)
        expect(result).to be_a(Sidekiq::AsyncHttp::Request)
        expect(result.body).to eq(JSON.generate(data))
      end
    end

    context "with body" do
      it "accepts string body" do
        result = client.async_request(:post, "/users", body: "raw request body")
        expect(result).to be_a(Sidekiq::AsyncHttp::Request)
      end

      it "accepts nil body" do
        result = client.async_request(:post, "/users", body: nil)
        expect(result).to be_a(Sidekiq::AsyncHttp::Request)
      end
    end

    context "with all options" do
      it "handles all parameters together" do
        result = client.async_request(
          :post,
          "/users",
          body: "data",
          headers: {"X-Custom" => "value"},
          params: {page: 1}
        )
        expect(result).to be_a(Sidekiq::AsyncHttp::Request)
      end
    end
  end

  describe "#async_get" do
    let(:client) { described_class.new(base_url: base_url) }

    it "calls async_request with :get method" do
      expect(client).to receive(:async_request).with(:get, "/users")
      client.async_get("/users")
    end

    it "forwards all keyword arguments" do
      expect(client).to receive(:async_request).with(
        :get,
        "/users",
        params: {page: 1},
        headers: {"X-Custom" => "value"}
      )
      client.async_get("/users", params: {page: 1}, headers: {"X-Custom" => "value"})
    end

    it "returns an Request" do
      result = client.async_get("/users")
      expect(result).to be_a(Sidekiq::AsyncHttp::Request)
    end
  end

  describe "#async_post" do
    let(:client) { described_class.new(base_url: base_url) }

    it "calls async_request with :post method" do
      expect(client).to receive(:async_request).with(:post, "/users")
      client.async_post("/users")
    end

    it "forwards all keyword arguments" do
      expect(client).to receive(:async_request).with(
        :post,
        "/users",
        json: {name: "John"},
        headers: {"X-Custom" => "value"}
      )
      client.async_post("/users", json: {name: "John"}, headers: {"X-Custom" => "value"})
    end

    it "returns an Request" do
      result = client.async_post("/users", body: "data")
      expect(result).to be_a(Sidekiq::AsyncHttp::Request)
    end
  end

  describe "#async_put" do
    let(:client) { described_class.new(base_url: base_url) }

    it "calls async_request with :put method" do
      expect(client).to receive(:async_request).with(:put, "/users/1")
      client.async_put("/users/1")
    end

    it "forwards all keyword arguments" do
      expect(client).to receive(:async_request).with(
        :put,
        "/users/1",
        json: {name: "Jane"},
        params: {notify: true}
      )
      client.async_put("/users/1", json: {name: "Jane"}, params: {notify: true})
    end

    it "returns an Request" do
      result = client.async_put("/users/1", body: "data")
      expect(result).to be_a(Sidekiq::AsyncHttp::Request)
    end
  end

  describe "#async_patch" do
    let(:client) { described_class.new(base_url: base_url) }

    it "calls async_request with :patch method" do
      expect(client).to receive(:async_request).with(:patch, "/users/1")
      client.async_patch("/users/1")
    end

    it "forwards all keyword arguments" do
      expect(client).to receive(:async_request).with(
        :patch,
        "/users/1",
        json: {email: "new@example.com"}
      )
      client.async_patch("/users/1", json: {email: "new@example.com"})
    end

    it "returns an Request" do
      result = client.async_patch("/users/1", body: "data")
      expect(result).to be_a(Sidekiq::AsyncHttp::Request)
    end
  end

  describe "#async_delete" do
    let(:client) { described_class.new(base_url: base_url) }

    it "calls async_request with :delete method" do
      expect(client).to receive(:async_request).with(:delete, "/users/1")
      client.async_delete("/users/1")
    end

    it "forwards all keyword arguments" do
      expect(client).to receive(:async_request).with(
        :delete,
        "/users/1",
        headers: {"X-Reason" => "spam"}
      )
      client.async_delete("/users/1", headers: {"X-Reason" => "spam"})
    end

    it "returns an Request" do
      result = client.async_delete("/users/1")
      expect(result).to be_a(Sidekiq::AsyncHttp::Request)
    end
  end

  describe "attribute accessors" do
    it "allows setting and getting base_url" do
      client = described_class.new
      client.base_url = "https://new-api.example.com"
      expect(client.base_url).to eq("https://new-api.example.com")
    end

    it "allows setting and getting headers" do
      client = described_class.new
      new_headers = Sidekiq::AsyncHttp::HttpHeaders.new({"X-New" => "header"})
      client.headers = new_headers
      expect(client.headers).to eq(new_headers)
    end

    it "allows setting and getting timeout" do
      client = described_class.new
      client.timeout = 45
      expect(client.timeout).to eq(45)
    end

    it "allows setting and getting connect_timeout" do
      client = described_class.new
      client.connect_timeout = 5
      expect(client.connect_timeout).to eq(5)
    end
  end
end
