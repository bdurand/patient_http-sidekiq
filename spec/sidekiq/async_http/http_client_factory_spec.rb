# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::HttpClientFactory do
  let(:config) { Sidekiq::AsyncHttp.configuration }
  let(:factory) { described_class.new(config) }

  let(:request) do
    Sidekiq::AsyncHttp::Request.new(
      :get,
      "https://api.example.com/users",
      headers: {"Accept" => "application/json"},
      timeout: 30,
      connect_timeout: 5.0
    )
  end

  describe ".new" do
    it "stores the configuration" do
      expect(factory.config).to eq(config)
    end
  end

  describe "#build" do
    it "returns a wrapped HTTP client" do
      client = factory.build(request)
      expect(client).to be_a(Protocol::HTTP::AcceptEncoding)
    end
  end
end
