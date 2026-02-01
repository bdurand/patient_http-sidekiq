# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Sidekiq::AsyncHttp::ExternalStorage do
  let(:temp_dir) { Dir.mktmpdir("external_storage_test") }

  before do
    Sidekiq::AsyncHttp.configure do |config|
      config.register_payload_store(:test, :file, directory: temp_dir)
      config.payload_store_threshold = 300 # Threshold that allows small response (~240 bytes) but not large ones
    end
  end

  after do
    Sidekiq::AsyncHttp.reset_configuration!
    FileUtils.rm_rf(temp_dir)
  end

  describe "included in Response" do
    let(:small_response) do
      Sidekiq::AsyncHttp::Response.new(
        status: 200,
        headers: {"content-type" => "application/json"},
        body: "small",
        duration: 0.1,
        request_id: "test-id",
        url: "http://example.com",
        http_method: :get
      )
    end

    let(:large_response) do
      Sidekiq::AsyncHttp::Response.new(
        status: 200,
        headers: {"content-type" => "application/json"},
        body: "x" * 500, # Makes total JSON ~700 bytes, well above 300 threshold
        duration: 0.1,
        request_id: "test-id",
        url: "http://example.com",
        http_method: :get
      )
    end

    describe "#store" do
      it "does not store when payload is below threshold" do
        small_response.store
        expect(small_response.stored?).to be false
      end

      it "stores when payload exceeds threshold" do
        large_response.store
        expect(large_response.stored?).to be true
        expect(large_response.store_key).to match(/^[0-9a-f-]{36}$/)
        expect(large_response.store_name).to eq(:test)
      end

      it "is idempotent" do
        large_response.store
        key = large_response.store_key
        large_response.store
        expect(large_response.store_key).to eq(key)
      end

      it "does not store when no payload store is configured" do
        Sidekiq::AsyncHttp.reset_configuration!
        large_response.store
        expect(large_response.stored?).to be false
      end
    end

    describe "#stored?" do
      it "returns false initially" do
        expect(large_response.stored?).to be false
      end

      it "returns true after storing" do
        large_response.store
        expect(large_response.stored?).to be true
      end
    end

    describe "#unstore" do
      it "removes the stored payload" do
        large_response.store
        key = large_response.store_key

        store = Sidekiq::AsyncHttp.configuration.payload_store
        expect(store.exists?(key)).to be true

        large_response.unstore
        expect(large_response.stored?).to be false
        expect(store.exists?(key)).to be false
      end

      it "is idempotent" do
        large_response.store
        large_response.unstore
        expect { large_response.unstore }.not_to raise_error
      end

      it "does nothing when not stored" do
        expect { small_response.unstore }.not_to raise_error
      end
    end

    describe "#as_json" do
      it "returns full data when not stored" do
        json = small_response.as_json
        expect(json).to include("status" => 200)
        expect(json).to include("headers")
        expect(json).to include("body")
      end

      it "returns reference when stored" do
        large_response.store
        json = large_response.as_json

        expect(json.keys).to eq(["$ref"])
        expect(json["$ref"]["store"]).to eq("test")
        expect(json["$ref"]["key"]).to match(/^[0-9a-f-]{36}$/)
      end
    end

    describe ".load" do
      it "loads from inline data" do
        json = small_response.as_json
        loaded = Sidekiq::AsyncHttp::Response.load(json)

        expect(loaded.status).to eq(200)
        expect(loaded.body).to eq("small")
      end

      it "loads from external storage reference" do
        large_response.store
        json = large_response.as_json
        key = large_response.store_key

        loaded = Sidekiq::AsyncHttp::Response.load(json)

        expect(loaded.status).to eq(200)
        expect(loaded.body).to eq("x" * 500)
        expect(loaded.stored?).to be true
        expect(loaded.store_key).to eq(key)
      end

      it "raises error when store is not registered" do
        large_response.store
        json = large_response.as_json

        # Simulate unregistered store
        Sidekiq::AsyncHttp.reset_configuration!

        expect { Sidekiq::AsyncHttp::Response.load(json) }.to raise_error(
          RuntimeError,
          /Payload store 'test' not registered/
        )
      end

      it "raises error when payload is not found" do
        large_response.store
        json = large_response.as_json

        # Delete the stored file
        Sidekiq::AsyncHttp.configuration.payload_store.delete(large_response.store_key)

        expect { Sidekiq::AsyncHttp::Response.load(json) }.to raise_error(
          RuntimeError,
          /Stored payload not found/
        )
      end
    end
  end

  describe "included in Request" do
    let(:small_request) do
      Sidekiq::AsyncHttp::Request.new(:get, "http://example.com")
    end

    let(:large_request) do
      Sidekiq::AsyncHttp::Request.new(
        :post,
        "http://example.com",
        body: "x" * 500, # Makes total JSON ~640 bytes, well above 300 threshold
        headers: {"content-type" => "application/json"}
      )
    end

    describe "#store and #as_json" do
      it "stores large requests and returns reference" do
        large_request.store
        expect(large_request.stored?).to be true

        json = large_request.as_json
        expect(json.keys).to eq(["$ref"])
      end

      it "does not store small requests" do
        small_request.store
        expect(small_request.stored?).to be false
      end
    end

    describe ".load" do
      it "loads from external storage reference" do
        large_request.store
        json = large_request.as_json

        loaded = Sidekiq::AsyncHttp::Request.load(json)

        expect(loaded.http_method).to eq(:post)
        expect(loaded.body).to eq("x" * 500)
        expect(loaded.stored?).to be true
      end
    end
  end

  describe "migration between stores" do
    let(:old_dir) { Dir.mktmpdir("old_store") }
    let(:new_dir) { Dir.mktmpdir("new_store") }

    after do
      FileUtils.rm_rf(old_dir)
      FileUtils.rm_rf(new_dir)
    end

    it "reads from old store while writing to new store" do
      # Setup old store and create a stored response
      Sidekiq::AsyncHttp.configure do |config|
        config.register_payload_store(:old_store, :file, directory: old_dir)
        config.payload_store_threshold = 300
      end

      response1 = Sidekiq::AsyncHttp::Response.new(
        status: 200,
        headers: {},
        body: "x" * 500,
        duration: 0.1,
        request_id: "old-id",
        url: "http://example.com",
        http_method: :get
      )
      response1.store
      old_json = response1.as_json
      expect(old_json["$ref"]["store"]).to eq("old_store")

      # Register new store as default, keeping old store registered
      Sidekiq::AsyncHttp.configure do |config|
        config.register_payload_store(:old_store, :file, directory: old_dir)
        config.register_payload_store(:new_store, :file, directory: new_dir)
        config.payload_store_threshold = 300
      end

      # New writes go to new store
      response2 = Sidekiq::AsyncHttp::Response.new(
        status: 200,
        headers: {},
        body: "y" * 500,
        duration: 0.1,
        request_id: "new-id",
        url: "http://example.com",
        http_method: :get
      )
      response2.store
      new_json = response2.as_json
      expect(new_json["$ref"]["store"]).to eq("new_store")

      # Can still load from old store
      loaded_old = Sidekiq::AsyncHttp::Response.load(old_json)
      expect(loaded_old.body).to eq("x" * 500)
      expect(loaded_old.store_name).to eq(:old_store)

      # Can load from new store
      loaded_new = Sidekiq::AsyncHttp::Response.load(new_json)
      expect(loaded_new.body).to eq("y" * 500)
      expect(loaded_new.store_name).to eq(:new_store)
    end
  end
end
