# frozen_string_literal: true

require "time"
require "sidekiq/web"

module Sidekiq
  module AsyncHttp
    # Web UI extension for Sidekiq
    # Adds an "Async HTTP" tab to the main Sidekiq dashboard
    # Works with Sidekiq 7.3+ and 8.0+
    class WebUI
      ROOT = File.join(__dir__, "web_ui")
      VIEWS = File.join(ROOT, "views")

      class << self
        # This method is called by Sidekiq::Web when registering the extension
        def registered(app)
          # GET route for the main Async HTTP dashboard page
          app.get "/async-http" do
            stats = Sidekiq::AsyncHttp::Stats.new

            # Get process-level inflight and capacity data
            all_inflight = stats.get_all_inflight
            processes = all_inflight.transform_values do |data|
              {
                inflight: data[:count],
                max_capacity: data[:max]
              }
            end

            # Get totals and calculate derived values
            totals = stats.get_totals
            total_requests = totals["requests"] || 0
            avg_duration = (total_requests > 0) ? ((totals["duration"] || 0).to_f / total_requests).round(3) : 0.0

            # Capacity metrics
            max_capacity = stats.get_total_max_connections
            current_inflight = stats.get_total_inflight
            utilization = (max_capacity > 0) ? (current_inflight.to_f / max_capacity * 100).round(1) : 0

            erb(:async_http, views: Sidekiq::AsyncHttp::WebUI::VIEWS, locals: {
              totals: totals,
              total_requests: total_requests,
              avg_duration: avg_duration,
              max_capacity: max_capacity,
              current_inflight: current_inflight,
              utilization: utilization,
              processes: processes
            })
          end

          # POST route for clearing statistics
          app.post "/async-http/clear" do
            Sidekiq::AsyncHttp::Stats.new.reset!
            redirect "#{root_path}async-http"
          end

          # API endpoint for fetching stats as JSON
          app.get "/api/async-http/stats" do
            stats = Sidekiq::AsyncHttp::Stats.new

            # Get process-level inflight and capacity data
            all_inflight = stats.get_all_inflight
            processes = all_inflight.transform_values do |data|
              {
                inflight: data[:count],
                max_capacity: data[:max]
              }
            end

            # Compile response
            response = {
              totals: stats.get_totals,
              current_inflight: stats.get_total_inflight,
              max_capacity: stats.get_total_max_connections,
              processes: processes,
              timestamp: Time.now.utc.iso8601
            }

            json(response)
          end
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
