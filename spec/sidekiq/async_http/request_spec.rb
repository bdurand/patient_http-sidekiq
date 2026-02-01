# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Request do
  describe "#initialize" do
    it "creates a request with valid parameters" do
      request = described_class.new(
        :get,
        "https://api.example.com/users",
        headers: {"Authorization" => "Bearer token"},
        body: nil,
        timeout: 30
      )

      expect(request.http_method).to eq(:get)
      expect(request.url).to eq("https://api.example.com/users")
      expect(request.headers.to_h).to eq("authorization" => "Bearer token")
      expect(request.body).to be_nil
      expect(request.timeout).to eq(30)
    end

    it "allows overriding the configured User-Agent header" do
      Sidekiq::AsyncHttp.configure do |config|
        config.user_agent = "Sidekiq-AsyncHttp-Test"
      end
      request = described_class.new(:get, "https://api.example.com/users", headers: {"User-Agent" => "Custom-Agent"})
      expect(request.headers["user-agent"]).to eq("Custom-Agent")
    ensure
      Sidekiq::AsyncHttp.reset_configuration!
    end

    it "accepts a URI object for url" do
      uri = URI("https://api.example.com/users")
      request = described_class.new(:get, uri)

      expect(request.url).to eq(uri.to_s)
    end

    it "accepts max_redirects parameter" do
      request = described_class.new(:get, "https://api.example.com", max_redirects: 10)
      expect(request.max_redirects).to eq(10)
    end

    it "allows max_redirects of 0 to disable redirects" do
      request = described_class.new(:get, "https://api.example.com", max_redirects: 0)
      expect(request.max_redirects).to eq(0)
    end

    it "defaults max_redirects to nil" do
      request = described_class.new(:get, "https://api.example.com")
      expect(request.max_redirects).to be_nil
    end

    context "validation" do
      it "casts method to a symbol" do
        request = described_class.new("POST", "https://example.com")
        expect(request.http_method).to eq(:post)
      end

      it "validates method is a valid HTTP method" do
        expect do
          described_class.new(:invalid, "https://example.com")
        end.to raise_error(ArgumentError, /method must be one of/)
      end

      it "accepts all valid HTTP methods" do
        %i[get post put patch delete].each do |method|
          expect do
            described_class.new(method, "https://example.com")
          end.not_to raise_error
        end
      end

      it "validates url is present" do
        expect do
          described_class.new(:get, nil)
        end.to raise_error(ArgumentError, "url is required")
      end

      it "validates url is not empty" do
        expect do
          described_class.new(:get, "")
        end.to raise_error(ArgumentError, "url is required")
      end

      it "validates url is a String or URI" do
        expect do
          described_class.new(:get, 123)
        end.to raise_error(ArgumentError, "url must be a String or URI, got: Integer")
      end

      it "validates body is not allowed for GET requests" do
        expect do
          described_class.new(:get, "https://example.com", body: "some body")
        end.to raise_error(ArgumentError, "body is not allowed for GET requests")
      end

      it "validates body is not allowed for DELETE requests" do
        expect do
          described_class.new(:delete, "https://example.com", body: "some body")
        end.to raise_error(ArgumentError, "body is not allowed for DELETE requests")
      end

      it "validates body must be a String when provided" do
        expect do
          described_class.new(:post, "https://example.com", body: {data: "value"})
        end.to raise_error(ArgumentError, "body must be a String, got: Hash")
      end

      it "allows nil body for POST requests" do
        expect do
          described_class.new(:post, "https://example.com", body: nil)
        end.not_to raise_error
      end

      it "allows String body for POST requests" do
        expect do
          described_class.new(:post, "https://example.com", body: '{"data":"value"}')
        end.not_to raise_error
      end
    end
  end

  describe "#as_json" do
    it "returns a hash representation of the request" do
      request = described_class.new(
        :post,
        "https://api.example.com/data",
        headers: {"Content-Type" => "application/json"},
        body: '{"key":"value"}',
        timeout: 15,
        max_redirects: 5
      )
      json = request.as_json
      expect(json).to eq(
        "http_method" => "post",
        "url" => "https://api.example.com/data",
        "headers" => {"content-type" => "application/json"},
        "body" => '{"key":"value"}',
        "timeout" => 15,
        "max_redirects" => 5
      )
    end

    it "can reload the object from the json representation" do
      original_request = described_class.new(
        :put,
        "https://api.example.com/update",
        headers: {"Accept" => "application/json"},
        body: '{"update":"data"}',
        timeout: 20,
        max_redirects: 3
      )
      json = original_request.as_json
      reloaded_request = described_class.load(json)
      expect(reloaded_request.http_method).to eq(original_request.http_method)
      expect(reloaded_request.url).to eq(original_request.url)
      expect(reloaded_request.headers.to_h).to eq(original_request.headers.to_h)
      expect(reloaded_request.body).to eq(original_request.body)
      expect(reloaded_request.timeout).to eq(original_request.timeout)
      expect(reloaded_request.max_redirects).to eq(original_request.max_redirects)
    end
  end

  describe "#execute" do
    let(:request) { described_class.new(:get, "https://example.com") }
    let(:job_hash) { {"class" => "TestWorker", "args" => [1, 2, 3]} }
    let(:processor) { instance_double(Sidekiq::AsyncHttp::Processor) }

    before do
      allow(Sidekiq::AsyncHttp).to receive(:processor).and_return(processor)
      TestCallback.reset_calls!
    end

    context "when processor is running" do
      before do
        allow(processor).to receive(:running?).and_return(true)
        allow(processor).to receive(:enqueue)
      end

      it "returns the request ID" do
        result = request.execute(
          sidekiq_job: job_hash,
          callback: TestCallback
        )

        expect(result).to be_a(String)
      end

      it "enqueues a RequestTask to the processor" do
        expect(processor).to receive(:enqueue) do |task|
          expect(task).to be_a(Sidekiq::AsyncHttp::RequestTask)
          expect(task.request).to eq(request)
          expect(task.sidekiq_job).to eq(job_hash)
          expect(task.callback).to eq("TestCallback")
        end

        request.execute(
          sidekiq_job: job_hash,
          callback: TestCallback
        )
      end

      it "sets enqueued_at on the task" do
        captured_task = nil
        allow(processor).to receive(:enqueue) do |task|
          task.enqueued! # Manually call since we're intercepting
          captured_task = task
        end

        request.execute(
          sidekiq_job: job_hash,
          callback: TestCallback
        )

        expect(captured_task).not_to be_nil
        expect(captured_task.enqueued_at).to be_a(Time)
        expect(captured_task.enqueued_at).to be <= Time.now
      end

      context "with callback_args" do
        it "passes callback_args to the RequestTask" do
          captured_task = nil
          allow(processor).to receive(:enqueue) { |task| captured_task = task }

          request.execute(
            sidekiq_job: job_hash,
            callback: TestCallback,
            callback_args: {custom: "args", action: "test"}
          )

          expect(captured_task.callback_args).to eq({"custom" => "args", "action" => "test"})
        end

        it "requires callback_args to be a hash" do
          allow(processor).to receive(:enqueue)

          expect do
            request.execute(
              sidekiq_job: job_hash,
              callback: TestCallback,
              callback_args: "single_value"
            )
          end.to raise_error(ArgumentError, /callback_args must respond to to_h/)
        end

        it "uses callback_args when provided" do
          captured_task = nil
          allow(processor).to receive(:enqueue) { |task| captured_task = task }

          request.execute(
            sidekiq_job: job_hash,
            callback: TestCallback,
            callback_args: {custom: "args"}
          )

          expect(captured_task.callback_args).to eq({"custom" => "args"})
        end

        it "defaults to empty hash when callback_args is not provided" do
          captured_task = nil
          allow(processor).to receive(:enqueue) { |task| captured_task = task }

          request.execute(
            sidekiq_job: job_hash,
            callback: TestCallback
          )

          expect(captured_task.callback_args).to eq({})
        end
      end
    end

    context "when processor is not running" do
      before do
        allow(processor).to receive(:running?).and_return(false)
      end

      it "raises NotRunningError" do
        expect do
          request.execute(
            sidekiq_job: job_hash,
            callback: TestCallback
          )
        end.to raise_error(Sidekiq::AsyncHttp::NotRunningError, /processor is not running/)
      end

      it "does not enqueue to processor" do
        expect(processor).not_to receive(:enqueue)

        begin
          request.execute(
            sidekiq_job: job_hash,
            callback: TestCallback
          )
        rescue Sidekiq::AsyncHttp::NotRunningError
          # Expected
        end
      end
    end

    context "validation" do
      before do
        allow(processor).to receive(:running?).and_return(true)
      end

      it "validates callback class has required methods" do
        expect do
          request.execute(sidekiq_job: job_hash, callback: String)
        end.to raise_error(ArgumentError, "callback class must define #on_complete instance method")
      end

      it "validates sidekiq_job is a Hash" do
        expect do
          request.execute(sidekiq_job: "not a hash", callback: TestCallback)
        end.to raise_error(ArgumentError, "sidekiq_job must be a Hash, got: String")
      end

      it "validates sidekiq_job has 'class' key" do
        expect do
          request.execute(
            sidekiq_job: {"args" => []},
            callback: TestCallback
          )
        end.to raise_error(ArgumentError, "sidekiq_job must have 'class' key")
      end

      it "validates sidekiq_job has 'args' array" do
        expect do
          request.execute(
            sidekiq_job: {"class" => "TestWorker", "args" => "not an array"},
            callback: TestCallback
          )
        end.to raise_error(ArgumentError, "sidekiq_job must have 'args' array")
      end

      it "uses Context.current_job when sidekiq_job is not provided" do
        allow(processor).to receive(:enqueue)
        allow(Sidekiq::AsyncHttp::Context).to receive(:current_job).and_return(job_hash)

        request.execute(callback: TestCallback)

        expect(processor).to have_received(:enqueue)
      end

      it "raises error when sidekiq_job is not provided and Context.current_job is nil" do
        allow(Sidekiq::AsyncHttp::Context).to receive(:current_job).and_return(nil)

        expect do
          request.execute(callback: TestCallback)
        end.to raise_error(ArgumentError, /sidekiq_job is required/)
      end

      it "accepts a string callback class name" do
        allow(processor).to receive(:enqueue)

        expect do
          request.execute(sidekiq_job: job_hash, callback: "TestCallback")
        end.not_to raise_error
      end
    end
  end

  describe "#async_execute" do
    it "enqueues the request using RequestWorker" do
      request = described_class.new(:get, "https://example.com")

      request_id = request.async_execute(
        callback: TestCallback,
        raise_error_responses: true,
        callback_args: {info: "data"}
      )

      job_args = Sidekiq::AsyncHttp::RequestWorker.jobs.first["args"]
      request_data, callback_name, raise_error_responses, callback_args, req_id = job_args
      async_request = Sidekiq::AsyncHttp::Request.load(request_data)

      expect(async_request.http_method).to eq(:get)
      expect(async_request.url).to eq("https://example.com")
      expect(callback_name).to eq("TestCallback")
      expect(raise_error_responses).to eq(true)
      expect(callback_args).to eq({"info" => "data"})
      expect(req_id).to eq(request_id)
    end

    it "validates the callback class" do
      request = described_class.new(:get, "https://example.com")

      expect do
        request.async_execute(callback: String)
      end.to raise_error(ArgumentError, "callback class must define #on_complete instance method")
    end

    it "validates callback_args is a hash-like object" do
      request = described_class.new(:get, "https://example.com")

      expect do
        request.async_execute(
          callback: TestCallback,
          callback_args: "not a hash"
        )
      end.to raise_error(ArgumentError, /callback_args must respond to to_h/)
    end
  end
end
