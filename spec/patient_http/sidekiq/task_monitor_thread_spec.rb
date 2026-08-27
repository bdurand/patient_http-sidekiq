# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::TaskMonitorThread do
  let(:config) do
    PatientHttp::Sidekiq::Configuration.new(
      heartbeat_interval: 1,
      orphan_threshold: 300,
      logger: Logger.new(File::NULL)
    )
  end
  let(:task_monitor) { PatientHttp::Sidekiq::TaskMonitor.new(config) }
  let(:monitor_thread) { described_class.new(config, task_monitor, -> { ["task-1"] }) }

  describe "#start" do
    after { monitor_thread.stop }

    it "starts the monitor thread" do
      monitor_thread.start

      expect(monitor_thread.running?).to be true
    end

    it "does not start a second thread when already running" do
      monitor_thread.start
      first_thread = monitor_thread.instance_variable_get(:@thread)

      monitor_thread.start

      expect(monitor_thread.instance_variable_get(:@thread)).to be(first_thread)
    end
  end

  describe "#start" do
    after { monitor_thread.stop }

    it "publishes the process capacity before the thread starts" do
      monitor_thread.start

      expect(PatientHttp::Sidekiq::TaskMonitor.total_max_connections).to eq(config.max_connections)
    end
  end

  describe "error handling", :disable_testing_mode do
    it "does not raise when the process registration fails outside of testing mode" do
      allow(task_monitor).to receive(:ping_process).and_raise(RuntimeError.new("redis down"))

      expect { monitor_thread.send(:ping_process) }.not_to raise_error
    end

    it "does not raise when heartbeat updates fail outside of testing mode" do
      allow(task_monitor).to receive(:update_heartbeats).and_raise(RuntimeError.new("redis down"))

      expect { monitor_thread.send(:update_heartbeats) }.not_to raise_error
    end

    it "does not raise when garbage collection fails outside of testing mode" do
      allow(task_monitor).to receive(:gc_needed?).and_raise(RuntimeError.new("redis down"))

      expect { monitor_thread.send(:attempt_garbage_collection) }.not_to raise_error
    end
  end

  describe "error handling in testing mode" do
    it "raises when heartbeat updates fail" do
      allow(task_monitor).to receive(:update_heartbeats).and_raise(RuntimeError.new("redis down"))

      expect { monitor_thread.send(:update_heartbeats) }.to raise_error("redis down")
    end
  end
end
