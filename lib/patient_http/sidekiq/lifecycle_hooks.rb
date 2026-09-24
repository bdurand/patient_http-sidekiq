# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Registers Sidekiq server lifecycle hooks that manage the processors.
    #
    # The hooks do the following:
    #
    # - Start the processors when the Sidekiq server starts (+:startup+ event).
    # - Drain the processors when Sidekiq receives the TSTP signal (+:quiet+
    #   event).
    # - Stop the processors when the Sidekiq server shuts down (+:shutdown+
    #   event).
    class LifecycleHooks
      @registered = false

      class << self
        # Registers the lifecycle hooks and the context middleware. The gem
        # calls this method when it loads. Repeated calls have no effect.
        #
        # @return [void]
        def register
          return if @registered

          PatientHttp::Sidekiq.append_middleware

          ::Sidekiq.configure_server do |config|
            config.on(:startup) do
              PatientHttp::Sidekiq.start
            end

            config.on(:quiet) do
              PatientHttp::Sidekiq.quiet
            end

            config.on(:shutdown) do
              PatientHttp::Sidekiq.stop
            end

            @registered = true
          end
        end
      end
    end
  end
end
