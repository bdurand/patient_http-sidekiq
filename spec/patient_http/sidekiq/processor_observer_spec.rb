# frozen_string_literal: true

require "spec_helper"

# Sidekiq 7.0's API file requires base64, which Ruby 3.4 no longer provides as
# a default gem, so the dead set is not reachable on every supported version.
dead_set_available = begin
  require "sidekiq/api"
  true
rescue LoadError
  false
end

RSpec.describe PatientHttp::Sidekiq::ProcessorObserver do
  let(:config) { PatientHttp::Sidekiq::Configuration.new }
  let(:processor) { PatientHttp::Processor.new(config) }
  let(:stats) { PatientHttp::Sidekiq::Stats.new(config) }
  let(:task_monitor) { PatientHttp::Sidekiq::TaskMonitor.new(config) }
  let(:observer) { described_class.new(processor, stats: stats, task_monitor: task_monitor) }

  let(:sidekiq_job) do
    {"class" => "TestWorker", "jid" => "observer-test-jid", "args" => []}
  end

  def build_task
    PatientHttp::RequestTask.new(
      request: PatientHttp::Request.new(:get, "https://example.com"),
      task_handler: PatientHttp::Sidekiq::TaskHandler.new(sidekiq_job),
      callback: TestCallback
    )
  end

  describe "#request_end" do
    it "unregisters the task and records the request" do
      task = build_task
      task.started!
      task_monitor.register(task)

      observer.request_end(task)

      expect(task_monitor.registered?(task)).to be(false)
      expect(stats.get_totals["requests"]).to eq(1)
    end

    it "does not unregister again or record a stat for a requeued task" do
      task = build_task
      task.started!
      task_monitor.register(task)

      observer.request_requeued(task)
      expect(task_monitor.registered?(task)).to be(false)

      # Re-register to prove request_end does not remove the entry again: the
      # job system owns the request, so a fresh registration (from the retried
      # job) must survive the trailing request_end of the shutdown sequence.
      task_monitor.register(task)
      observer.request_end(task)

      expect(task_monitor.registered?(task)).to be(true)
      expect(stats.get_totals["requests"]).to eq(0)
    end

    it "treats the requeued marker as one-shot" do
      task = build_task
      task.started!

      observer.request_requeued(task)
      observer.request_end(task)

      # A later, unrelated request_end for the same id behaves normally.
      task_monitor.register(task)
      observer.request_end(task)
      expect(task_monitor.registered?(task)).to be(false)
      expect(stats.get_totals["requests"]).to eq(1)
    end
  end

  describe "#completion_failed" do
    it "keeps the crash-recovery record and records an error stat" do
      task = build_task
      task_monitor.register(task)

      observer.completion_failed(task, StandardError.new("redis blip"))

      expect(task_monitor.registered?(task)).to be(true)
      totals = stats.get_totals
      expect(totals["errors"]).to eq(1)
      expect(totals["error_type_counts"]).to eq("completion_failed" => 1)
    end

    context "with a result that can never be delivered" do
      let(:error) { JSON::GeneratorError.new(%("\xE0" from ASCII-8BIT to UTF-8)) }

      it "removes the crash-recovery record so nothing re-enqueues the request", if: dead_set_available do
        task = build_task
        task.started!
        task_monitor.register(task)

        observer.completion_failed(task, error)

        expect(task_monitor.registered?(task)).to be(false)
      end

      it "records the request and the error", if: dead_set_available do
        task = build_task
        task.started!
        task_monitor.register(task)

        observer.completion_failed(task, error)

        totals = stats.get_totals
        expect(totals["requests"]).to eq(1)
        expect(totals["errors"]).to eq(1)
        expect(totals["error_type_counts"]).to eq("undeliverable_result" => 1)
      end

      it "moves the job to the dead set", if: dead_set_available do
        task = build_task
        task.started!
        task_monitor.register(task)

        observer.completion_failed(task, error)

        dead = ::Sidekiq::DeadSet.new.to_a
        expect(dead.size).to eq(1)
        expect(dead.first.item["class"]).to eq("TestWorker")
        expect(dead.first.item["jid"]).to eq("observer-test-jid")
        expect(dead.first.item["error_class"]).to eq("JSON::GeneratorError")
      end

      it "recognizes the failure when it is the cause of another error", if: dead_set_available do
        task = build_task
        task.started!
        task_monitor.register(task)

        wrapped = begin
          begin
            raise error
          rescue
            raise "could not push the callback job"
          end
        rescue => e
          e
        end

        observer.completion_failed(task, wrapped)

        expect(task_monitor.registered?(task)).to be(false)
        expect(stats.get_totals["error_type_counts"]).to eq("undeliverable_result" => 1)
      end

      it "gives a directly executed request a job id for the dead set", if: dead_set_available do
        args = [{"url" => "https://example.com"}, "TestCallback", false, nil, "request-id", "default"]
        handler = PatientHttp::Sidekiq::DirectTaskHandler.new(args)
        task = PatientHttp::RequestTask.new(
          request: PatientHttp::Request.new(:get, "https://example.com"),
          task_handler: handler,
          callback: TestCallback
        )
        task.started!
        task_monitor.register(task)

        observer.completion_failed(task, error)

        dead = ::Sidekiq::DeadSet.new.to_a
        expect(dead.size).to eq(1)
        expect(dead.first.item["jid"]).to match(/\A[0-9a-f]{24}\z/)
        expect(dead.first.item["class"]).to eq("PatientHttp::Sidekiq::RequestWorker")
      end
    end
  end

  describe "per-processor stats" do
    it "does not tag stats when only the default profile exists" do
      task = build_task
      task.started!
      task_monitor.register(task)

      observer.request_end(task)

      expect(stats.get_totals).not_to have_key("processors")
    end

    it "tags stats with the processor name when multiple profiles are configured" do
      config.processor(:llm, max_connections: 10)
      named_processor = PatientHttp::Processor.new(config, name: :llm)
      named_observer = described_class.new(named_processor, stats: stats, task_monitor: task_monitor)

      task = build_task
      task.started!
      task_monitor.register(task)
      named_observer.request_end(task)

      totals = stats.get_totals
      expect(totals["processors"]).to have_key("llm")
      expect(totals["processors"]["llm"]["requests"]).to eq(1)
    end

    it "tags errors and capacity rejections with the processor name" do
      config.processor(:llm, max_connections: 10)
      named_processor = PatientHttp::Processor.new(config, name: :llm)
      named_observer = described_class.new(named_processor, stats: stats, task_monitor: task_monitor)

      named_observer.request_error(RuntimeError.new("boom"))
      named_observer.capacity_exceeded

      counts = stats.get_totals["processors"]["llm"]
      expect(counts["errors"]).to eq(1)
      expect(counts["max_capacity_exceeded"]).to eq(1)
    end
  end
end
