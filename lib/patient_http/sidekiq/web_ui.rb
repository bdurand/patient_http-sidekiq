# frozen_string_literal: true

require "sidekiq/web"

module PatientHttp
  module Sidekiq
    # Web UI extension for Sidekiq
    # Adds an "Async HTTP" tab to the main Sidekiq dashboard
    # Works with Sidekiq 7.3+ and 8.0+
    class WebUI
      ROOT = File.join(__dir__, "web_ui")
      VIEWS = File.join(ROOT, "views")

      class << self
        # This method is called by Sidekiq::Web when registering the extension
        def registered(app)
          # GET route for the main PatientHttp dashboard page
          app.get "/patient-http" do
            stats = PatientHttp::Sidekiq::Stats.new

            # Get process-level inflight and capacity data from TaskMonitor
            processes = PatientHttp::Sidekiq::TaskMonitor.inflight_counts_by_process

            # Get totals and calculate derived values
            totals = stats.get_totals
            total_requests = totals["requests"] || 0
            avg_duration = (total_requests > 0) ? ((totals["duration"] || 0).to_f / total_requests).round(3) : 0.0

            # Capacity metrics from TaskMonitor
            max_capacity = processes.values.sum { |data| data[:max_capacity] }
            current_inflight = processes.values.sum { |data| data[:inflight] }
            utilization = (max_capacity > 0) ? (current_inflight.to_f / max_capacity * 100).round(1) : 0

            erb(:patient_http, views: PatientHttp::Sidekiq::WebUI::VIEWS, locals: {
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
          app.post "/patient-http/clear" do
            PatientHttp::Sidekiq::Stats.new.reset!
            redirect "#{root_path}patient-http"
          end
        end
      end
    end
  end

  # Auto-register the web UI extension if Sidekiq::Web is available
  # This is called after require "sidekiq/web" in the application
  if defined?(::Sidekiq::Web)
    ::Sidekiq::Web.configure do |config|
      config.register_extension(
        PatientHttp::Sidekiq::WebUI,
        name: "patient-http",
        tab: "patient_http.tab",
        index: "patient-http",
        root_dir: PatientHttp::Sidekiq::WebUI::ROOT,
        asset_paths: ["css", "js"]
      )
    end
  end
end
