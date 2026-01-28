# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::SerializeResponseMiddleware do
  let(:middleware) { described_class.new }
  let(:worker_class) { "TestWorker" }
  let(:queue) { "default" }
  let(:redis_pool) { nil }

  describe "#call" do
    context "with a Response object as first argument" do
      let(:response) do
        Sidekiq::AsyncHttp::Response.new(
          status: 200,
          headers: {"Content-Type" => "application/json"},
          body: '{"message":"success"}',
          duration: 0.123,
          request_id: "req-123",
          url: "https://api.example.com/users",
          http_method: :get
        )
      end

      let(:job) do
        {
          "class" => "TestWorker",
          "jid" => "test-123",
          "args" => [response, "arg2", "arg3"]
        }
      end

      it "serializes the Response object to a hash" do
        middleware.call(worker_class, job, queue, redis_pool) {}

        first_arg = job["args"][0]
        expect(first_arg).to be_a(Hash)
        expect(first_arg["_sidekiq_async_http_class"]).to eq("Sidekiq::AsyncHttp::Response")
        expect(first_arg["status"]).to eq(200)
        expect(first_arg["request_id"]).to eq("req-123")
        expect(first_arg["url"]).to eq("https://api.example.com/users")
        expect(first_arg["http_method"]).to eq("get")
      end

      it "preserves other arguments" do
        middleware.call(worker_class, job, queue, redis_pool) {}

        expect(job["args"][1]).to eq("arg2")
        expect(job["args"][2]).to eq("arg3")
      end

      it "yields to the next middleware" do
        yielded = false
        middleware.call(worker_class, job, queue, redis_pool) do
          yielded = true
        end

        expect(yielded).to be true
      end
    end

    context "with a RequestError object as first argument" do
      let(:error) do
        Sidekiq::AsyncHttp::RequestError.new(
          class_name: "Timeout::Error",
          message: "Request timed out",
          backtrace: ["line 1", "line 2"],
          error_type: :timeout,
          duration: 0.5,
          request_id: "req-456",
          url: "https://api.example.com/slow",
          http_method: :post
        )
      end

      let(:job) do
        {
          "class" => "TestWorker",
          "jid" => "test-456",
          "args" => [error, "arg2"]
        }
      end

      it "serializes the RequestError object to a hash" do
        middleware.call(worker_class, job, queue, redis_pool) {}

        first_arg = job["args"][0]
        expect(first_arg).to be_a(Hash)
        expect(first_arg["_sidekiq_async_http_class"]).to eq("Sidekiq::AsyncHttp::RequestError")
        expect(first_arg["class_name"]).to eq("Timeout::Error")
        expect(first_arg["message"]).to eq("Request timed out")
        expect(first_arg["error_type"]).to eq("timeout")
        expect(first_arg["request_id"]).to eq("req-456")
      end

      it "preserves other arguments" do
        middleware.call(worker_class, job, queue, redis_pool) {}

        expect(job["args"][1]).to eq("arg2")
      end

      it "yields to the next middleware" do
        yielded = false
        middleware.call(worker_class, job, queue, redis_pool) do
          yielded = true
        end

        expect(yielded).to be true
      end
    end

    context "with an HttpError object as first argument" do
      let(:response) do
        Sidekiq::AsyncHttp::Response.new(
          status: 404,
          headers: {"Content-Type" => "application/json"},
          body: '{"error":"not found"}',
          duration: 0.234,
          request_id: "req-789",
          url: "https://api.example.com/users/999",
          http_method: :get
        )
      end

      let(:http_error) do
        Sidekiq::AsyncHttp::HttpError.new(response)
      end

      let(:job) do
        {
          "class" => "TestWorker",
          "jid" => "test-789",
          "args" => [http_error, "arg2"]
        }
      end

      it "serializes the HttpError object to a hash" do
        middleware.call(worker_class, job, queue, redis_pool) {}

        first_arg = job["args"][0]
        expect(first_arg).to be_a(Hash)
        expect(first_arg["_sidekiq_async_http_class"]).to eq("Sidekiq::AsyncHttp::ClientError")
        expect(first_arg["response"]).to be_a(Hash)
        expect(first_arg["response"]["status"]).to eq(404)
        expect(first_arg["response"]["request_id"]).to eq("req-789")
      end

      it "preserves other arguments" do
        middleware.call(worker_class, job, queue, redis_pool) {}

        expect(job["args"][1]).to eq("arg2")
      end

      it "yields to the next middleware" do
        yielded = false
        middleware.call(worker_class, job, queue, redis_pool) do
          yielded = true
        end

        expect(yielded).to be true
      end
    end

    context "with regular arguments" do
      let(:job) do
        {
          "class" => "TestWorker",
          "jid" => "test-789",
          "args" => ["string_arg", 123, {"key" => "value"}]
        }
      end

      it "does not modify regular arguments" do
        original_args = job["args"].dup

        middleware.call(worker_class, job, queue, redis_pool) {}

        expect(job["args"]).to eq(original_args)
      end

      it "yields to the next middleware" do
        yielded = false
        middleware.call(worker_class, job, queue, redis_pool) do
          yielded = true
        end

        expect(yielded).to be true
      end
    end

    context "with empty arguments" do
      let(:job) do
        {
          "class" => "TestWorker",
          "jid" => "test-empty",
          "args" => []
        }
      end

      it "does not raise an error" do
        expect do
          middleware.call(worker_class, job, queue, redis_pool) {}
        end.not_to raise_error
      end

      it "yields to the next middleware" do
        yielded = false
        middleware.call(worker_class, job, queue, redis_pool) do
          yielded = true
        end

        expect(yielded).to be true
      end
    end

    context "with Response object not as first argument" do
      let(:response) do
        Sidekiq::AsyncHttp::Response.new(
          status: 200,
          headers: {},
          body: "test",
          duration: 0.1,
          request_id: "req-999",
          url: "https://example.com",
          http_method: :get
        )
      end

      let(:job) do
        {
          "class" => "TestWorker",
          "jid" => "test-999",
          "args" => ["string_arg", response, "arg3"]
        }
      end

      it "does not serialize Response objects in other positions" do
        middleware.call(worker_class, job, queue, redis_pool) {}

        expect(job["args"][0]).to eq("string_arg")
        expect(job["args"][1]).to be_a(Sidekiq::AsyncHttp::Response)
        expect(job["args"][2]).to eq("arg3")
      end
    end

    context "with already serialized Response" do
      let(:job) do
        {
          "class" => "TestWorker",
          "jid" => "test-serialized",
          "args" => [
            {
              "_sidekiq_async_http_class" => "Sidekiq::AsyncHttp::Response",
              "status" => 200,
              "request_id" => "req-123"
            },
            "arg2"
          ]
        }
      end

      it "does not double-serialize the hash" do
        original_first_arg = job["args"][0]

        middleware.call(worker_class, job, queue, redis_pool) {}

        expect(job["args"][0]).to eq(original_first_arg)
      end
    end
  end
end
