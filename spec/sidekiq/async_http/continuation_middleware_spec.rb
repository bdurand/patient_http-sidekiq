# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::ContinuationMiddleware do
  let(:middleware) { described_class.new }
  let(:worker) { double("Worker") }
  let(:queue) { "default" }

  let(:response_data) do
    {
      "status" => 200,
      "headers" => {"Content-Type" => "application/json"},
      "body" => {"encoding" => "text", "value" => '{"message":"success"}'},
      "duration" => 0.123,
      "request_id" => "req-123",
      "url" => "https://api.example.com/users",
      "http_method" => "get",
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
      "http_method" => "post"
    }
  end

  after do
    Sidekiq::AsyncHttp.instance_variable_set(:@after_completion_callbacks, [])
    Sidekiq::AsyncHttp.instance_variable_set(:@after_errors, [])
  end

  describe "#call" do
    it "yields control for regular jobs" do
      job = {
        "class" => "TestWorker",
        "jid" => "test-123",
        "args" => ["arg1", "arg2"]
      }

      yielded = false
      middleware.call(worker, job, queue) do
        yielded = true
      end

      expect(yielded).to be true
    end

    it "yields control for jobs without async_http_continuation" do
      job = {
        "class" => "TestWorker",
        "jid" => "test-123",
        "args" => ["arg1", "arg2"]
      }

      yielded = false
      middleware.call(worker, job, queue) do
        yielded = true
      end

      expect(yielded).to be true
    end

    context "when processing completion continuation jobs" do
      let(:job) do
        {
          "class" => "TestWorker::CompletionCallback",
          "jid" => "test-123",
          "args" => [response_data, "original_arg1", "original_arg2"],
          "async_http_continuation" => "completion"
        }
      end

      it "invokes completion callbacks before yielding" do
        responses = []
        Sidekiq::AsyncHttp.after_completion do |response|
          responses << response
        end

        yielded = false
        middleware.call(worker, job, queue) do
          yielded = true
        end

        expect(yielded).to be true
        expect(responses.size).to eq(1)
        expect(responses.first).to be_a(Sidekiq::AsyncHttp::Response)
        expect(responses.first.status).to eq(200)
        expect(responses.first.request_id).to eq("req-123")
      end

      it "invokes multiple registered completion callbacks" do
        responses = []

        Sidekiq::AsyncHttp.after_completion do |response|
          responses << [:first, response]
        end

        Sidekiq::AsyncHttp.after_completion do |response|
          responses << [:second, response]
        end

        Sidekiq::AsyncHttp.after_completion do |response|
          responses << [:third, response]
        end

        middleware.call(worker, job, queue) {}

        expect(responses.size).to eq(3)
        expect(responses.map(&:first)).to eq([:first, :second, :third])
        expect(responses.map(&:last).map(&:class).uniq).to eq([Sidekiq::AsyncHttp::Response])
      end

      it "passes the response data from job args to callbacks" do
        response_received = nil

        Sidekiq::AsyncHttp.after_completion do |response|
          response_received = response
        end

        middleware.call(worker, job, queue) {}

        expect(response_received.url).to eq("https://api.example.com/users")
        expect(response_received.http_method).to eq(:get)
        expect(response_received.status).to eq(200)
        expect(response_received.body).to eq('{"message":"success"}')
      end

      it "still yields even if no callbacks are registered" do
        yielded = false
        middleware.call(worker, job, queue) do
          yielded = true
        end

        expect(yielded).to be true
      end
    end

    context "when processing error continuation jobs" do
      let(:job) do
        {
          "class" => "TestWorker::ErrorCallback",
          "jid" => "test-456",
          "args" => [error_data, "original_arg1", "original_arg2"],
          "async_http_continuation" => "error"
        }
      end

      it "invokes error callbacks before yielding" do
        errors = []
        Sidekiq::AsyncHttp.after_error do |error|
          errors << error
        end

        yielded = false
        middleware.call(worker, job, queue) do
          yielded = true
        end

        expect(yielded).to be true
        expect(errors.size).to eq(1)
        expect(errors.first).to be_a(Sidekiq::AsyncHttp::Error)
        expect(errors.first.error_class).to eq(Timeout::Error)
        expect(errors.first.request_id).to eq("req-456")
      end

      it "invokes multiple registered error callbacks" do
        errors = []

        Sidekiq::AsyncHttp.after_error do |error|
          errors << [:first, error]
        end

        Sidekiq::AsyncHttp.after_error do |error|
          errors << [:second, error]
        end

        Sidekiq::AsyncHttp.after_error do |error|
          errors << [:third, error]
        end

        middleware.call(worker, job, queue) {}

        expect(errors.size).to eq(3)
        expect(errors.map(&:first)).to eq([:first, :second, :third])
        expect(errors.map(&:last).map(&:class).uniq).to eq([Sidekiq::AsyncHttp::Error])
      end

      it "passes the error data from job args to callbacks" do
        error_received = nil

        Sidekiq::AsyncHttp.after_error do |error|
          error_received = error
        end

        middleware.call(worker, job, queue) {}

        expect(error_received.error_class).to eq(Timeout::Error)
        expect(error_received.message).to eq("Request timed out")
        expect(error_received.error_type).to eq(:timeout)
        expect(error_received.url).to eq("https://api.example.com/slow")
        expect(error_received.http_method).to eq(:post)
      end

      it "still yields even if no callbacks are registered" do
        yielded = false
        middleware.call(worker, job, queue) do
          yielded = true
        end

        expect(yielded).to be true
      end
    end

    it "does not invoke callbacks for unknown continuation types" do
      job = {
        "class" => "TestWorker",
        "jid" => "test-789",
        "args" => [response_data],
        "async_http_continuation" => "unknown"
      }

      responses = []
      errors = []

      Sidekiq::AsyncHttp.after_completion do |response|
        responses << response
      end

      Sidekiq::AsyncHttp.after_error do |error|
        errors << error
      end

      middleware.call(worker, job, queue) {}

      expect(responses).to be_empty
      expect(errors).to be_empty
    end
  end
end
