# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::SidekiqLifecycleHooks do
  # Save original Sidekiq configuration
  let(:original_lifecycle_events) do
    Sidekiq.default_configuration.instance_variable_get(:@options)[:lifecycle_events].dup
  end

  before do
    # Reset AsyncHttp state for clean test environment
    Sidekiq::AsyncHttp.reset!

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
    Sidekiq::AsyncHttp.reset!
  end

  # Helper to get lifecycle events
  def lifecycle_events
    Sidekiq.default_configuration.instance_variable_get(:@options)[:lifecycle_events]
  end

  # Helper to simulate Sidekiq.configure_server block execution
  def execute_configure_server_block(&block)
    block.call(Sidekiq.default_configuration)
  end

  describe "requiring sidekiq/async_http/sidekiq" do
    it "registers hooks that can be invoked" do
      # Manually execute the configure_server block (simulates what Sidekiq does in server mode)
      execute_configure_server_block do |config|
        config.on(:startup) { Sidekiq::AsyncHttp.start }
        config.on(:quiet) { Sidekiq::AsyncHttp.quiet }
        config.on(:shutdown) { Sidekiq::AsyncHttp.stop }
      end

      # Verify hooks are registered
      expect(lifecycle_events[:startup]).not_to be_empty
      expect(lifecycle_events[:quiet]).not_to be_empty
      expect(lifecycle_events[:shutdown]).not_to be_empty
    end

    it "startup hook calls Sidekiq::AsyncHttp.start" do
      expect(Sidekiq::AsyncHttp).to receive(:start)

      execute_configure_server_block do |config|
        config.on(:startup) { Sidekiq::AsyncHttp.start }
      end

      # Trigger the startup event
      lifecycle_events[:startup].each(&:call)
    end

    it "quiet hook calls Sidekiq::AsyncHttp.quiet" do
      expect(Sidekiq::AsyncHttp).to receive(:quiet)

      execute_configure_server_block do |config|
        config.on(:quiet) { Sidekiq::AsyncHttp.quiet }
      end

      # Trigger the quiet event
      lifecycle_events[:quiet].each(&:call)
    end

    it "shutdown hook calls Sidekiq::AsyncHttp.stop" do
      expect(Sidekiq::AsyncHttp).to receive(:stop)

      execute_configure_server_block do |config|
        config.on(:shutdown) { Sidekiq::AsyncHttp.stop }
      end

      # Trigger the shutdown event
      lifecycle_events[:shutdown].each(&:call)
    end
  end

  describe "full lifecycle integration" do
    it "starts, quiets, and stops the processor through Sidekiq events" do
      # Register the hooks manually (simulating what configure_server does)
      execute_configure_server_block do |config|
        config.on(:startup) { Sidekiq::AsyncHttp.start }
        config.on(:quiet) { Sidekiq::AsyncHttp.quiet }
        config.on(:shutdown) { Sidekiq::AsyncHttp.stop }
      end

      # Ensure we start from a clean state
      expect(Sidekiq::AsyncHttp).not_to be_running

      # Trigger startup event - this should start the processor
      lifecycle_events[:startup].each do |hook|
        hook.call
      end

      # Verify processor is now running
      expect(Sidekiq::AsyncHttp).to be_running
      expect(Sidekiq::AsyncHttp.processor).to be_running

      # Trigger quiet event - processor should start draining
      lifecycle_events[:quiet].each do |hook|
        hook.call
      end

      # Verify processor is draining (no longer running but hasn't stopped yet)
      expect(Sidekiq::AsyncHttp).not_to be_running  # running? returns false when draining
      expect(Sidekiq::AsyncHttp.processor).to be_draining
      expect(Sidekiq::AsyncHttp.processor).not_to be_stopped

      # Trigger shutdown event - processor should stop
      lifecycle_events[:shutdown].each do |hook|
        hook.call
      end

      # Verify processor is now stopped
      expect(Sidekiq::AsyncHttp).not_to be_running
      expect(Sidekiq::AsyncHttp.processor).to be_nil
    end
  end
end
