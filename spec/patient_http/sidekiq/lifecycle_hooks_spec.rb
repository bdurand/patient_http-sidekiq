# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::LifecycleHooks do
  # Save original Sidekiq configuration
  let(:original_lifecycle_events) do
    Sidekiq.default_configuration.instance_variable_get(:@options)[:lifecycle_events].dup
  end

  before do
    # Reset Sidekiq state for clean test environment
    PatientHttp::Sidekiq.reset!

    # Save and clear existing lifecycle events for clean test state
    @saved_lifecycle_events = Sidekiq.default_configuration.instance_variable_get(:@options)[:lifecycle_events].dup
    Sidekiq.default_configuration.instance_variable_get(:@options)[:lifecycle_events].each do |event, hooks|
      hooks.clear
    end
  end

  after do
    # Restore original lifecycle events
    Sidekiq.default_configuration.instance_variable_get(:@options)[:lifecycle_events].each do |event, hooks|
      hooks.clear
      hooks.concat(@saved_lifecycle_events[event])
    end
    PatientHttp::Sidekiq.reset!
  end

  # Helper to get lifecycle events
  def lifecycle_events
    Sidekiq.default_configuration.instance_variable_get(:@options)[:lifecycle_events]
  end

  # Helper to simulate Sidekiq.configure_server block execution
  def execute_configure_server_block(&block)
    block.call(Sidekiq.default_configuration)
  end

  describe "requiring sidekiq/patient_http/sidekiq" do
    it "registers hooks that can be invoked" do
      # Manually execute the configure_server block (simulates what Sidekiq does in server mode)
      execute_configure_server_block do |config|
        config.on(:startup) { PatientHttp::Sidekiq.start }
        config.on(:quiet) { PatientHttp::Sidekiq.quiet }
        config.on(:shutdown) { PatientHttp::Sidekiq.stop }
      end

      # Verify hooks are registered
      expect(lifecycle_events[:startup]).not_to be_empty
      expect(lifecycle_events[:quiet]).not_to be_empty
      expect(lifecycle_events[:shutdown]).not_to be_empty
    end

    it "startup hook calls PatientHttp::Sidekiq.start" do
      expect(PatientHttp::Sidekiq).to receive(:start)

      execute_configure_server_block do |config|
        config.on(:startup) { PatientHttp::Sidekiq.start }
      end

      # Trigger the startup event
      lifecycle_events[:startup].each(&:call)
    end

    it "quiet hook calls PatientHttp::Sidekiq.quiet" do
      expect(PatientHttp::Sidekiq).to receive(:quiet)

      execute_configure_server_block do |config|
        config.on(:quiet) { PatientHttp::Sidekiq.quiet }
      end

      # Trigger the quiet event
      lifecycle_events[:quiet].each(&:call)
    end

    it "shutdown hook calls PatientHttp::Sidekiq.stop" do
      expect(PatientHttp::Sidekiq).to receive(:stop)

      execute_configure_server_block do |config|
        config.on(:shutdown) { PatientHttp::Sidekiq.stop }
      end

      # Trigger the shutdown event
      lifecycle_events[:shutdown].each(&:call)
    end
  end

  describe "full lifecycle integration" do
    it "starts, quiets, and stops the processor through Sidekiq events" do
      # Register the hooks manually (simulating what configure_server does)
      execute_configure_server_block do |config|
        config.on(:startup) { PatientHttp::Sidekiq.start }
        config.on(:quiet) { PatientHttp::Sidekiq.quiet }
        config.on(:shutdown) { PatientHttp::Sidekiq.stop }
      end

      # Ensure we start from a clean state
      expect(PatientHttp::Sidekiq).not_to be_running

      # Trigger startup event - this should start the processor
      lifecycle_events[:startup].each do |hook|
        hook.call
      end

      # Verify processor is now running
      expect(PatientHttp::Sidekiq).to be_running
      expect(PatientHttp::Sidekiq.processor).to be_running

      # Trigger quiet event - processor should start draining
      lifecycle_events[:quiet].each do |hook|
        hook.call
      end

      # Verify processor is draining (no longer running but hasn't stopped yet)
      expect(PatientHttp::Sidekiq).not_to be_running  # running? returns false when draining
      expect(PatientHttp::Sidekiq.processor).to be_draining
      expect(PatientHttp::Sidekiq.processor).not_to be_stopped

      # Trigger shutdown event - processor should stop
      lifecycle_events[:shutdown].each do |hook|
        hook.call
      end

      # Verify processor is now stopped
      expect(PatientHttp::Sidekiq).not_to be_running
      expect(PatientHttp::Sidekiq.processor).to be_nil
    end
  end
end
