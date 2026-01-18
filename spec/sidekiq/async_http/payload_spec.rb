# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Payload do
  describe ".encode" do
    context "with text mimetype" do
      let(:mimetype) { "text/plain" }

      it "returns :text encoding for small text" do
        value = "small text"
        encoding, encoded = described_class.encode(value, mimetype)
        expect(encoding).to eq(:text)
        expect(encoded).to eq(value)
      end

      it "returns :gzipped encoding for large compressible text" do
        value = "repeat " * 1000  # compressible
        encoding, encoded = described_class.encode(value, mimetype)
        expect(encoding).to eq(:gzipped)
        expect(encoded).to be_a(String)
        expect(encoded).not_to eq(value)
      end
    end

    context "with binary mimetype" do
      let(:mimetype) { "application/octet-stream" }

      it "returns :binary encoding" do
        value = "binary data"
        encoding, encoded = described_class.encode(value, mimetype)
        expect(encoding).to eq(:binary)
        expect(encoded).to eq(Base64.encode64(value).chomp)
      end
    end

    context "with json mimetype" do
      let(:mimetype) { "application/json" }

      it "treats as text" do
        value = '{"key": "value"}'
        encoding, _encoded = described_class.encode(value, mimetype)
        expect(encoding).to eq(:text)
      end
    end
  end

  describe ".decode" do
    it "decodes :text" do
      value = "plain text"
      expect(described_class.decode(value, :text)).to eq(value)
    end

    it "decodes :binary" do
      value = "binary data"
      encoded = Base64.encode64(value).chomp
      expect(described_class.decode(encoded, :binary)).to eq(value)
    end

    it "decodes :gzipped" do
      value = "compressible text " * 100
      gzipped = Zlib::Deflate.deflate(value)
      encoded = Base64.encode64(gzipped).chomp
      expect(described_class.decode(encoded, :gzipped)).to eq(value)
    end
  end

  describe "#value" do
    it "decodes the encoded value" do
      encoded = Base64.encode64("test").chomp
      payload = described_class.new(:binary, encoded)
      expect(payload.value).to eq("test")
    end
  end

  describe "#to_h" do
    it "returns hash with string keys" do
      payload = described_class.new(:text, "data")
      hash = payload.to_h
      expect(hash).to eq({
        "encoding" => "text",
        "value" => "data"
      })
    end
  end

  describe ".from_h" do
    it "creates payload from hash" do
      hash = {
        "mimetype" => "text/plain",
        "encoding" => "text",
        "value" => "data"
      }
      payload = described_class.from_h(hash)
      expect(payload.encoding).to eq(:text)
      expect(payload.encoded_value).to eq("data")
      expect(payload.value).to eq("data")
    end
  end

  describe "round trip" do
    it "encodes and decodes correctly" do
      original_value = "test data"
      mimetype = "text/plain"
      encoding, encoded_value = described_class.encode(original_value, mimetype)
      payload = described_class.new(encoding, encoded_value)
      expect(payload.value).to eq(original_value)
      hash = payload.to_h
      restored = described_class.from_h(hash)
      expect(restored.value).to eq(original_value)
    end

    it "encodes and decodes nil value" do
      original_value = nil
      mimetype = "text/plain"
      encoding, encoded_value = described_class.encode(original_value, mimetype)
      expect(encoding).to be_nil
      expect(encoded_value).to be_nil
      payload = described_class.new(encoding, encoded_value)
      expect(payload.value).to be_nil
      hash = payload.to_h
      restored = described_class.from_h(hash)
      expect(restored).to be_nil
      expect(described_class.from_h(nil)).to be_nil
    end
  end
end
