# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::RequestTask do
  let(:request) do
    Sidekiq::AsyncHttp::Request.new(
      method: :get,
      url: "https://api.example.com/users"
    )
  end

  let(:sidekiq_job) do
    {
      "class" => "TestHelper::Worker",
      "jid" => "job-123",
      "args" => [1, 2, 3],
      "queue" => "default",
      "retry" => true
    }
  end

  let(:success_worker) { "TestSuccessWorker" }
  let(:error_worker) { "TestErrorWorker" }

  describe "#initialize" do
    it "creates a task with required parameters" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker
      )

      expect(task.request).to eq(request)
      expect(task.sidekiq_job).to eq(sidekiq_job)
      expect(task.success_worker).to eq(success_worker)
      expect(task.error_worker).to be_nil
    end

    it "accepts an optional error_worker" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker,
        error_worker: error_worker
      )

      expect(task.error_worker).to eq(error_worker)
    end

    it "generates a unique ID" do
      task1 = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker
      )
      task2 = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker
      )

      expect(task1.id).to be_a(String)
      expect(task2.id).to be_a(String)
      expect(task1.id).not_to eq(task2.id)
    end

    it "initializes timing attributes to nil" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker
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
        success_worker: success_worker
      )

      expect(task.job_worker_class).to eq(TestHelper::Worker)
    end
  end

  describe "#jid" do
    it "returns the job ID from the Sidekiq job" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker
      )

      expect(task.jid).to eq("job-123")
    end
  end

  describe "#job_args" do
    it "returns the arguments from the Sidekiq job" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker
      )

      expect(task.job_args).to eq([1, 2, 3])
    end
  end

  describe "#enqueued_duration" do
    it "returns nil when not yet enqueued" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker
      )

      expect(task.enqueued_duration).to be_nil
    end
  end

  describe "#duration" do
    it "returns nil when not yet started" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker
      )

      expect(task.duration).to be_nil
    end
  end

  describe "#reenqueue_job" do
    it "re-enqueues the original Sidekiq job" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker
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
        success_worker: success_worker
      )

      expect(Sidekiq::Client).to receive(:push) do |job|
        expect(job["retry_count"]).to eq(2)
        expect(job["custom_field"]).to eq("value")
        "new-jid"
      end

      task.reenqueue_job
    end
  end

  describe "#retry_job" do
    it "increments retry count and re-enqueues" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker
      )

      expect(Sidekiq::Client).to receive(:push) do |job|
        expect(job["retry_count"]).to eq(1)
        expect(job["class"]).to eq("TestHelper::Worker")
        expect(job["args"]).to eq([1, 2, 3])
        "new-jid"
      end

      result = task.retry_job
      expect(result).to eq("new-jid")
    end

    it "increments existing retry count" do
      job_with_retry = sidekiq_job.merge("retry_count" => 3)
      task = described_class.new(
        request: request,
        sidekiq_job: job_with_retry,
        success_worker: success_worker
      )

      expect(Sidekiq::Client).to receive(:push) do |job|
        expect(job["retry_count"]).to eq(4)
        "new-jid"
      end

      task.retry_job
    end

    it "starts retry count at 1 when not present" do
      job_without_retry = sidekiq_job.dup
      job_without_retry.delete("retry_count")

      task = described_class.new(
        request: request,
        sidekiq_job: job_without_retry,
        success_worker: success_worker
      )

      expect(Sidekiq::Client).to receive(:push) do |job|
        expect(job["retry_count"]).to eq(1)
        "new-jid"
      end

      task.retry_job
    end
  end

  describe "#success" do
    it "is a no-op method for extension" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker
      )

      expect { task.success({status: 200}) }.not_to raise_error
    end
  end

  describe "#error" do
    it "is a no-op method for extension" do
      task = described_class.new(
        request: request,
        sidekiq_job: sidekiq_job,
        success_worker: success_worker
      )

      error = Sidekiq::AsyncHttp::Error.new(
        error_type: :timeout,
        message: "Timeout",
        class_name: "Async::TimeoutError",
        backtrace: [],
        request_id: "req-123"
      )

      expect { task.error(error) }.not_to raise_error
    end
  end
end
