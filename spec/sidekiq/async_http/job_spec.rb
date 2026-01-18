# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Job do
  let(:response_data) do
    {
      "status" => 200,
      "headers" => {"Content-Type" => "application/json"},
      "body" => {"encoding" => "text", "value" => '{"message":"success"}'},
      "duration" => 0.123,
      "request_id" => "req-123",
      "url" => "https://api.example.com/users",
      "method" => "get"
    }
  end

  let(:error_data) do
    {
      "class_name" => "Timeout::Error",
      "message" => "Request timed out",
      "backtrace" => ["line 1", "line 2", "line 3"],
      "error_type" => "timeout"
    }
  end

  describe "including Sidekiq::Job" do
    let(:worker_class) do
      Class.new do
        include Sidekiq::AsyncHttp::Job
      end
    end

    it "includes Sidekiq::Job in the including class" do
      expect(worker_class.included_modules).to include(Sidekiq::Job)
    end
  end

  describe ".on_completion" do
    let(:worker_class) do
      Class.new do
        include Sidekiq::AsyncHttp::Job

        @called_args = []

        on_completion(retry: false) do |response, *args|
          @called_args << [response, *args]
        end
      end
    end

    let(:called_args) { worker_class.instance_variable_get(:@called_args) }

    it "sets the success callback worker class" do
      expect(worker_class.completion_callback_worker).to eq(worker_class::CompletionCallback)
    end

    it "defines a CompletionCallback worker class" do
      worker_class::CompletionCallback.new.perform(response_data, "arg1", "arg2")
      expect(called_args.size).to eq(1)
      response, arg1, arg2 = called_args.first
      expect(response).to be_a(Sidekiq::AsyncHttp::Response)
      expect(response.status).to eq(200)
      expect(response.body).to eq('{"message":"success"}')
      expect(response.duration).to eq(0.123)
      expect(arg1).to eq("arg1")
      expect(arg2).to eq("arg2")
    end

    it "allows setting Sidekiq options" do
      sidekiq_options = worker_class::CompletionCallback.get_sidekiq_options
      expect(sidekiq_options["retry"]).to eq(false)
    end
  end

  describe ".on_error" do
    let(:worker_class) do
      Class.new do
        include Sidekiq::AsyncHttp::Job

        @called_args = []

        on_error(retry: false) do |error, *args|
          @called_args << [error, *args]
        end
      end
    end

    let(:called_args) { worker_class.instance_variable_get(:@called_args) }

    it "sets the error callback worker class" do
      expect(worker_class.error_callback_worker).to eq(worker_class::ErrorCallback)
    end

    it "defines an ErrorCallback worker class" do
      worker_class::ErrorCallback.new.perform(error_data, "err_arg1", "err_arg2")
      expect(called_args.size).to eq(1)
      error, arg1, arg2 = called_args.first
      expect(error).to be_a(Sidekiq::AsyncHttp::Error)
      expect(error.error_class).to eq(Timeout::Error)
      expect(error.message).to eq("Request timed out")
      expect(error.backtrace).to eq(["line 1", "line 2", "line 3"])
      expect(arg1).to eq("err_arg1")
      expect(arg2).to eq("err_arg2")
    end

    it "allows setting Sidekiq options" do
      sidekiq_options = worker_class::ErrorCallback.get_sidekiq_options
      expect(sidekiq_options["retry"]).to eq(false)
    end
  end

  describe "request helper methods" do
    let(:worker_class) do
      Class.new do
        include Sidekiq::AsyncHttp::Job

        @called_args = []

        on_completion do |response, *args|
          @called_args << [response, *args]
        end

        on_error do |error, *args|
          @called_args << [error, *args]
        end
      end
    end

    let(:request_tasks) { [] }

    let(:sidekiq_job) do
      {
        "class" => "TestWorkers::Worker",
        "jid" => "test-jid-789",
        "args" => ["param1", 456, "action"]
      }
    end

    let(:worker_instance) { worker_class.new }

    around do |example|
      Sidekiq::AsyncHttp::Context.with_job(sidekiq_job) do
        example.run
      end
    end

    before do
      Sidekiq::AsyncHttp.start

      allow(Sidekiq::AsyncHttp.processor).to receive(:enqueue) do |task|
        request_tasks << task
      end
    end

    after do
      Sidekiq::AsyncHttp.stop
    end

    describe "#async_request" do
      it "enqueues an async HTTP request with given method" do
        worker_instance.async_request(:get, "https://api.example.com/data", timeout: 10)
        expect(request_tasks.size).to eq(1)
        task = request_tasks.first
        expect(task.request).to be_a(Sidekiq::AsyncHttp::Request)
        expect(task.request.method).to eq(:get)
        expect(task.request.url).to eq("https://api.example.com/data")
        expect(task.request.timeout).to eq(10)
      end

      it "sets the success and error workers to the dynamically defined callback workers" do
        worker_instance.async_request(:post, "https://api.example.com/data", body: "payload", timeout: 15)
        task = request_tasks.first
        expect(task.completion_worker).to eq(worker_class::CompletionCallback)
        expect(task.error_worker).to eq(worker_class::ErrorCallback)
      end

      context "when success and error workers are set directly" do
        let(:worker_class) do
          Class.new do
            include Sidekiq::AsyncHttp::Job

            @called_args = []

            self.completion_callback_worker = TestWorkers::CompletionWorker
            self.error_callback_worker = TestWorkers::ErrorWorker
          end
        end

        it "can set the success worker class directly" do
          worker_instance.async_request(:put, "https://api.example.com/data/1", json: {name: "test"}, timeout: 20)
          task = request_tasks.first
          expect(task.completion_worker).to eq(TestWorkers::CompletionWorker)
        end

        it "can set the error worker class directly" do
          worker_instance.async_request(:delete, "https://api.example.com/data/1", timeout: 25)
          task = request_tasks.first
          expect(task.error_worker).to eq(TestWorkers::ErrorWorker)
        end
      end

      it "can override success and error workers" do
        worker_instance.async_request(
          :put,
          "https://api.example.com/data/1",
          json: {name: "test"},
          timeout: 20,
          completion_worker: TestWorkers::CompletionWorker,
          error_worker: TestWorkers::ErrorWorker
        )

        task = request_tasks.first
        expect(task.completion_worker).to eq(TestWorkers::CompletionWorker)
        expect(task.error_worker).to eq(TestWorkers::ErrorWorker)
      end

      it "does not pass an error worker to the request task if not defined" do
        worker_class_without_error_callback = Class.new do
          include Sidekiq::AsyncHttp::Job

          on_completion do |response, *args|
            # no-op
          end
        end

        worker_class_without_error_callback.new.async_request(:put, "https://api.example.com/data/1", timeout: 30)
        task = request_tasks.first
        expect(task.error_worker).to be_nil
        expect(task.completion_worker).to eq(worker_class_without_error_callback::CompletionCallback)
      end
    end

    describe "#async_get" do
      it "calls async_request with GET method" do
        expect(worker_instance).to receive(:async_request).with(:get, "https://api.example.com/data", timeout: 5)
        worker_instance.async_get("https://api.example.com/data", timeout: 5)
      end
    end

    describe "#async_post" do
      it "calls async_request with POST method" do
        expect(worker_instance).to receive(:async_request).with(:post, "https://api.example.com/data", body: "payload", timeout: 15)
        worker_instance.async_post("https://api.example.com/data", body: "payload", timeout: 15)
      end
    end

    describe "#async_put" do
      it "calls async_request with PUT method" do
        expect(worker_instance).to receive(:async_request).with(:put, "https://api.example.com/data/1", json: {name: "test"}, timeout: 20)
        worker_instance.async_put("https://api.example.com/data/1", json: {name: "test"}, timeout: 20)
      end
    end

    describe "#async_patch" do
      it "calls async_request with PATCH method" do
        expect(worker_instance).to receive(:async_request).with(:patch, "https://api.example.com/data/1", body: "update", timeout: 25)
        worker_instance.async_patch("https://api.example.com/data/1", body: "update", timeout: 25)
      end
    end

    describe "#async_delete" do
      it "calls async_request with DELETE method" do
        expect(worker_instance).to receive(:async_request).with(:delete, "https://api.example.com/data/1", timeout: 30)
        worker_instance.async_delete("https://api.example.com/data/1", timeout: 30)
      end
    end
  end
end
