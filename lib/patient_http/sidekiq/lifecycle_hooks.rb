# frozen_string_literal: true

# Sidekiq server lifecycle hooks for automatic Sidekiq processor management.
#
# This class registers lifecycle hooks with Sidekiq to automatically start, drain,
# and stop the Sidekiq processor along with the Sidekiq server.
##
# The hooks will:
# - Start the processor when Sidekiq server starts (:startup event)
# - Drain the processor when Sidekiq receives TSTP signal (:quiet event)
# - Stop the processor when Sidekiq shuts down (:shutdown event)
module PatientHttp
  module Sidekiq
    class LifecycleHooks
      @registered = false

      class << self
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
