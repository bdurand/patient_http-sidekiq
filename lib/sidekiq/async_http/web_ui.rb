# frozen_string_literal: true

require "time"

module Sidekiq
  module AsyncHttp
    # Web UI extension for Sidekiq
    # Adds an "Async HTTP" tab to the main Sidekiq dashboard
    # Works with Sidekiq 7.3+ and 8.0+
    class WebUI
      ROOT = File.join(__dir__, "web_ui")
      VIEWS = File.join(ROOT, "views")

      # This method is called by Sidekiq::Web when registering the extension
      def self.registered(app)
        # GET route for the main Async HTTP dashboard page
        app.get "/async-http" do
          erb(:async_http, views: Sidekiq::AsyncHttp::WebUI::VIEWS)
        end

        # API endpoint for fetching stats as JSON
        app.get "/api/async-http/stats" do
          stats = Sidekiq::AsyncHttp::Stats.instance

          # Get process-level inflight and capacity data
          all_inflight = stats.get_all_inflight
          processes = {}

          Sidekiq.redis do |redis|
            all_inflight.each do |identifier, inflight|
              max_conn_key = "#{Sidekiq::AsyncHttp::Stats::MAX_CONNECTIONS_PREFIX}:#{identifier}"
              max_connections = redis.get(max_conn_key).to_i
              processes[identifier] = {
                inflight: inflight,
                max_capacity: max_connections
              }
            end
          end

          # Compile response
          response = {
            totals: stats.get_totals,
            current_inflight: stats.get_total_inflight,
            max_capacity: stats.get_total_max_connections,
            processes: processes,
            timestamp: Time.now.iso8601
          }

          json(response)
        end
      end
    end
  end
end

# Auto-register the web UI extension if Sidekiq::Web is available
# This is called after require "sidekiq/web" in the application
if defined?(Sidekiq::Web)
  Sidekiq::Web.configure do |config|
    config.register_extension(
      Sidekiq::AsyncHttp::WebUI,
      name: "async-http",
      tab: "async_http.tab",
      index: "async-http",
      root_dir: Sidekiq::AsyncHttp::WebUI::ROOT,
      asset_paths: ["css", "js"]
    )
  end
end
