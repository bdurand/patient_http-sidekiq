# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::RequestTask do
  let(:request) do
    Sidekiq::AsyncHttp::Request.new(:get, "https://api.example.com/users")
  end

  let(:sidekiq_job) do
    {
      "class" => "TestWorkers::Worker",
      "jid" => "job-123",
      "args" => [1, 2, 3],
      "queue" => "default",
      "retry" => true
    }
  end

  let(:completion_worker) { "TestCompletionWorker" }
  let(:error_worker) { "TestErrorWorker" }

  describe "#initialize" do
    it "creates a task with required parameters" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker
      )

      expect(task.request).to eq(request)
      expect(task.sidekiq_job).to eq(sidekiq_job)
      expect(task.completion_worker).to eq(completion_worker)
      expect(task.error_worker).to eq(error_worker)
    end

    it "accepts an optional error_worker" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker
      )

      expect(task.error_worker).to eq(error_worker)
    end

    it "accepts optional callback_args as a hash" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker,
        callback_args: {user_id: 123, action: "fetch"}
      )

      expect(task.callback_args).to eq({user_id: 123, action: "fetch"})
    end

    it "defaults callback_args to an empty hash when not provided" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker
      )

      expect(task.callback_args).to eq({})
    end

    it "generates a unique ID" do
      task1 = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker
      )
      task2 = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker
      )

      expect(task1.id).to be_a(String)
      expect(task2.id).to be_a(String)
      expect(task1.id).not_to eq(task2.id)
    end

    it "initializes timing attributes to nil" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker
      )

      expect(task.enqueued_at).to be_nil
      expect(task.started_at).to be_nil
      expect(task.completed_at).to be_nil
    end
  end

  describe "#job_worker_class_name" do
    it "returns the worker class from the Sidekiq job" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker
      )

      expect(task.job_worker_class).to eq(TestWorkers::Worker)
    end
  end

  describe "#jid" do
    it "returns the job ID from the Sidekiq job" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker
      )

      expect(task.jid).to eq("job-123")
    end
  end

  describe "#enqueued_duration" do
    it "returns nil when not yet enqueued" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker
      )

      expect(task.enqueued_duration).to be_nil
    end
  end

  describe "#duration" do
    it "returns nil when not yet started" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker
      )

      expect(task.duration).to be_nil
    end
  end

  describe "#reenqueue_job" do
    it "re-enqueues the original Sidekiq job" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: completion_worker,
        error_worker: error_worker
      )

      expect(Sidekiq::Client).to receive(:push).with(sidekiq_job).and_return("new-jid")

      result = task.reenqueue_job
      expect(result).to eq("new-jid")
    end

    it "preserves all job attributes" do
      job_with_metadata = sidekiq_job.merge(
        "retry_count" => 2,
        "failed_at" => Time.now.to_f,
        "custom_field" => "value"
      )

      task = described_class.new(
        request: request,
        sidekiq_job: job_with_metadata,
        completion_worker: completion_worker,
        error_worker: error_worker
      )

      expect(Sidekiq::Client).to receive(:push) do |job|
        expect(job["retry_count"]).to eq(2)
        expect(job["custom_field"]).to eq("value")
        "new-jid"
      end

      task.reenqueue_job
    end
  end

  describe "#success!" do
    it "enqueues the success worker with response containing callback_args" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker",
        callback_args: {"user_id" => 123, "action" => "fetch"}
      )
      task.started!

      response = task.build_response(
        status: 200,
        headers: {},
        body: "OK"
      )

      task.success!(response)
      expect(task.response).to eq(response)
      expect(task.success?).to be(true)
      expect(TestWorkers::CompletionWorker.jobs.size).to eq(1)
      job = TestWorkers::CompletionWorker.jobs.first
      # Args should be a single element: the response with callback_args embedded
      expect(job["args"].size).to eq(1)
      response_json = job["args"].first
      expect(response_json["callback_args"]).to eq({"user_id" => 123, "action" => "fetch"})
    end

    it "uses empty callback_args when not provided" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker"
      )

      response = Sidekiq::AsyncHttp::Response.new(
        status: 200,
        headers: {},
        body: "OK",
        request_id: task.id,
        duration: 0.5,
        url: "https://api.example.com/users",
        http_method: :get
      )

      task.success!(response)
      expect(TestWorkers::CompletionWorker.jobs.size).to eq(1)
      job = TestWorkers::CompletionWorker.jobs.first
      expect(job["args"].size).to eq(1)
      response_json = job["args"].first
      expect(response_json["callback_args"]).to eq({})
    end
  end

  describe "#error!" do
    it "enqueues the error worker with error containing callback_args" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker",
        callback_args: {"user_id" => 123, "action" => "fetch"}
      )
      task.completed!

      exception = StandardError.new("Something went wrong")

      task.error!(exception)
      expect(task.error).to eq(exception)
      expect(task.error?).to be(true)
      expect(TestWorkers::ErrorWorker.jobs.size).to eq(1)
      job = TestWorkers::ErrorWorker.jobs.first
      # Args should be a single element: the error with callback_args embedded
      expect(job["args"].size).to eq(1)
      error_json = job["args"].first
      expect(error_json["callback_args"]).to eq({"user_id" => 123, "action" => "fetch"})
    end

    it "uses empty callback_args when not provided" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        completion_worker: "TestWorkers::CompletionWorker",
        error_worker: "TestWorkers::ErrorWorker"
      )
      task.completed!

      exception = StandardError.new("Something went wrong")

      task.error!(exception)
      expect(TestWorkers::ErrorWorker.jobs.size).to eq(1)
      job = TestWorkers::ErrorWorker.jobs.first
      expect(job["args"].size).to eq(1)
      error_json = job["args"].first
      expect(error_json["callback_args"]).to eq({})
    end
  end
end
