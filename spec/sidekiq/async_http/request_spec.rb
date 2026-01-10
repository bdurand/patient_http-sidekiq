# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::Request do
  # Define test worker classes
  class TestSuccessWorker
    include Sidekiq::Job
  end

  class TestErrorWorker
    include Sidekiq::Job
  end

  class ContextWorker
    include Sidekiq::Job
  end

  describe "#initialize" do
    it "creates a request with valid parameters" do
      request = described_class.new(
        method: :get,
        url: "https://api.example.com/users",
        headers: {"Authorization" => "Bearer token"},
        body: nil,
        timeout: 30
      )

      expect(request.method).to eq(:get)
      expect(request.url).to eq("https://api.example.com/users")
      expect(request.headers).to eq({"Authorization" => "Bearer token"})
      expect(request.body).to be_nil
      expect(request.timeout).to eq(30)
    end

    it "accepts a URI object for url" do
      uri = URI("https://api.example.com/users")
      request = described_class.new(method: :get, url: uri)

      expect(request.url).to eq(uri)
    end

    context "validation" do
      it "casts method to a symbol" do
        request = described_class.new(method: "POST", url: "https://example.com")
        expect(request.method).to eq(:post)
      end

      it "validates method is a valid HTTP method" do
        expect do
          described_class.new(method: :invalid, url: "https://example.com")
        end.to raise_error(ArgumentError, /method must be one of/)
      end

      it "accepts all valid HTTP methods" do
        %i[get post put patch delete].each do |method|
          expect do
            described_class.new(method: method, url: "https://example.com")
          end.not_to raise_error
        end
      end

      it "validates url is present" do
        expect do
          described_class.new(method: :get, url: nil)
        end.to raise_error(ArgumentError, "url is required")
      end

      it "validates url is not empty" do
        expect do
          described_class.new(method: :get, url: "")
        end.to raise_error(ArgumentError, "url is required")
      end

      it "validates url is a String or URI" do
        expect do
          described_class.new(method: :get, url: 123)
        end.to raise_error(ArgumentError, "url must be a String or URI, got: Integer")
      end
    end
  end

  describe "#perform" do
    let(:request) { described_class.new(method: :get, url: "https://example.com") }
    let(:job_hash) { {"class" => "TestWorker", "args" => [1, 2, 3]} }
    let(:processor) { instance_double(Sidekiq::AsyncHttp::Processor) }

    before do
      allow(Sidekiq::AsyncHttp).to receive(:processor).and_return(processor)
    end

    context "when processor is running" do
      before do
        allow(processor).to receive(:running?).and_return(true)
        allow(processor).to receive(:enqueue)
      end

      it "returns the request ID" do
        result = request.perform(
          sidekiq_job: job_hash,
          success_worker: TestSuccessWorker,
          error_worker: TestErrorWorker
        )

        expect(result).to eq(request.id)
        expect(result).to be_a(String)
      end

      it "enqueues a RequestTask to the processor" do
        expect(processor).to receive(:enqueue) do |task|
          expect(task).to be_a(Sidekiq::AsyncHttp::RequestTask)
          expect(task.request).to eq(request)
          expect(task.sidekiq_job).to eq(job_hash)
          expect(task.success_worker).to eq(TestSuccessWorker)
          expect(task.error_worker).to eq(TestErrorWorker)
        end

        request.perform(
          sidekiq_job: job_hash,
          success_worker: TestSuccessWorker,
          error_worker: TestErrorWorker
        )
      end

      it "sets enqueued_at on the task" do
        expect(processor).to receive(:enqueue) do |task|
          expect(task.enqueued_at).to be_a(Float)
          expect(task.enqueued_at).to be > 0
        end

        request.perform(
          sidekiq_job: job_hash,
          success_worker: TestSuccessWorker
        )
      end

      it "works with nil error_worker" do
        expect(processor).to receive(:enqueue) do |task|
          expect(task.error_worker).to be_nil
        end

        request.perform(
          sidekiq_job: job_hash,
          success_worker: TestSuccessWorker,
          error_worker: nil
        )
      end
    end

    context "when processor is not running" do
      before do
        allow(processor).to receive(:running?).and_return(false)
      end

      it "raises NotRunningError" do
        expect do
          request.perform(
            sidekiq_job: job_hash,
            success_worker: TestSuccessWorker
          )
        end.to raise_error(Sidekiq::AsyncHttp::NotRunningError, /processor is not running/)
      end

      it "does not enqueue to processor" do
        expect(processor).not_to receive(:enqueue)

        begin
          request.perform(
            sidekiq_job: job_hash,
            success_worker: TestSuccessWorker
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

      it "validates success_worker is required" do
        expect do
          request.perform(sidekiq_job: job_hash, success_worker: nil)
        end.to raise_error(ArgumentError, "success_worker is required")
      end

      it "validates success_worker is a class that includes Sidekiq::Job" do
        expect do
          request.perform(sidekiq_job: job_hash, success_worker: String)
        end.to raise_error(ArgumentError, "success_worker must be a class that includes Sidekiq::Job")
      end

      it "validates sidekiq_job is a Hash" do
        expect do
          request.perform(sidekiq_job: "not a hash", success_worker: TestSuccessWorker)
        end.to raise_error(ArgumentError, "sidekiq_job must be a Hash, got: String")
      end

      it "validates sidekiq_job has 'class' key" do
        expect do
          request.perform(sidekiq_job: {"args" => []}, success_worker: TestSuccessWorker)
        end.to raise_error(ArgumentError, "sidekiq_job must have 'class' key")
      end

      it "validates sidekiq_job has 'args' array" do
        expect do
          request.perform(sidekiq_job: {"class" => "Worker"}, success_worker: TestSuccessWorker)
        end.to raise_error(ArgumentError, "sidekiq_job must have 'args' array")
      end
    end
  end
end

