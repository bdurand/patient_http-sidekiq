# frozen_string_literal: true

# Sidekiq server lifecycle hooks for automatic AsyncHttp processor management.
#
# This class registers lifecycle hooks with Sidekiq to automatically start, drain,
# and stop the AsyncHttp processor along with the Sidekiq server.
##
# The hooks will:
# - Start the processor when Sidekiq server starts (:startup event)
# - Drain the processor when Sidekiq receives TSTP signal (:quiet event)
# - Stop the processor when Sidekiq shuts down (:shutdown event)
module Sidekiq::AsyncHttp
  class SidekiqLifecycleHooks
    @registered = false

    class << self
      def register
        return if @registered

        Sidekiq.configure_server do |config|
          config.server_middleware do |chain|
            chain.add Sidekiq::AsyncHttp::Context::Middleware
            chain.add Sidekiq::AsyncHttp::ContinuationMiddleware
          end

          config.on(:startup) do
            Sidekiq::AsyncHttp.start
          end

          config.on(:quiet) do
            Sidekiq::AsyncHttp.quiet
          end

          config.on(:shutdown) do
            Sidekiq::AsyncHttp.stop
          end

          @registered = true
        end
      end
    end
  end
end
