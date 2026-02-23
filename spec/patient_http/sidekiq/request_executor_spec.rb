# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::RequestExecutor do
  describe "#execute" do
    let(:request) { PatientHttp::Request.new(:get, "https://example.com") }
    let(:job_hash) { {"class" => "TestWorker", "args" => [1, 2, 3]} }
    let(:processor) { instance_double(PatientHttp::Processor) }

    before do
      allow(PatientHttp::Sidekiq).to receive(:processor).and_return(processor)
      TestCallback.reset_calls!
    end

    context "when processor is running" do
      before do
        allow(processor).to receive(:running?).and_return(true)
        allow(processor).to receive(:enqueue)
      end

      it "returns the request ID" do
        result = described_class.execute(
          request,
          sidekiq_job: job_hash,
          callback: TestCallback
        )

        expect(result).to be_a(String)
      end

      it "enqueues a RequestTask to the processor" do
        expect(processor).to receive(:enqueue) do |task|
          expect(task).to be_a(PatientHttp::RequestTask)
          expect(task.request).to eq(request)
          expect(task.task_handler.sidekiq_job).to eq(job_hash)
          expect(task.callback).to eq("TestCallback")
        end

        described_class.execute(
          request,
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

        described_class.execute(
          request,
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

          described_class.execute(
            request,
            sidekiq_job: job_hash,
            callback: TestCallback,
            callback_args: {custom: "args", action: "test"}
          )

          expect(captured_task.callback_args).to eq({"custom" => "args", "action" => "test"})
        end

        it "requires callback_args to be a hash" do
          allow(processor).to receive(:enqueue)

          expect do
            described_class.execute(
              request,
              sidekiq_job: job_hash,
              callback: TestCallback,
              callback_args: "single_value"
            )
          end.to raise_error(ArgumentError, /callback_args must respond to to_h/)
        end

        it "uses callback_args when provided" do
          captured_task = nil
          allow(processor).to receive(:enqueue) { |task| captured_task = task }

          described_class.execute(
            request,
            sidekiq_job: job_hash,
            callback: TestCallback,
            callback_args: {custom: "args"}
          )

          expect(captured_task.callback_args).to eq({"custom" => "args"})
        end

        it "defaults to empty hash when callback_args is not provided" do
          captured_task = nil
          allow(processor).to receive(:enqueue) { |task| captured_task = task }

          described_class.execute(
            request,
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
          described_class.execute(
            request,
            sidekiq_job: job_hash,
            callback: TestCallback
          )
        end.to raise_error(PatientHttp::NotRunningError, /processor is not running/)
      end

      it "does not enqueue to processor" do
        expect(processor).not_to receive(:enqueue)

        begin
          described_class.execute(
            request,
            sidekiq_job: job_hash,
            callback: TestCallback
          )
        rescue PatientHttp::NotRunningError
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
          described_class.execute(request, sidekiq_job: job_hash, callback: String)
        end.to raise_error(ArgumentError, "callback class must define #on_complete instance method")
      end

      it "validates sidekiq_job is a Hash" do
        expect do
          described_class.execute(request, sidekiq_job: "not a hash", callback: TestCallback)
        end.to raise_error(ArgumentError, "sidekiq_job must be a Hash, got: String")
      end

      it "validates sidekiq_job has 'class' key" do
        expect do
          described_class.execute(request, sidekiq_job: {"args" => []}, callback: TestCallback)
        end.to raise_error(ArgumentError, "sidekiq_job must have 'class' key")
      end

      it "validates sidekiq_job has 'args' array" do
        expect do
          described_class.execute(request, sidekiq_job: {"class" => "TestWorker", "args" => "not an array"}, callback: TestCallback)
        end.to raise_error(ArgumentError, "sidekiq_job must have 'args' array")
      end

      it "uses Context.current_job when sidekiq_job is not provided" do
        allow(processor).to receive(:enqueue)
        allow(PatientHttp::Sidekiq::Context).to receive(:current_job).and_return(job_hash)

        described_class.execute(request, callback: TestCallback)

        expect(processor).to have_received(:enqueue)
      end

      it "raises error when sidekiq_job is not provided and Context.current_job is nil" do
        allow(PatientHttp::Sidekiq::Context).to receive(:current_job).and_return(nil)

        expect do
          described_class.execute(request, callback: TestCallback)
        end.to raise_error(ArgumentError, /sidekiq_job is required/)
      end

      it "accepts a string callback class name" do
        allow(processor).to receive(:enqueue)

        expect do
          described_class.execute(request, sidekiq_job: job_hash, callback: "TestCallback")
        end.not_to raise_error
      end
    end
  end
end
