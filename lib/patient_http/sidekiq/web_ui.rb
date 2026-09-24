# frozen_string_literal: true

require "sidekiq/version"

# Sidekiq 7.3 introduced the web extension API used here (register with
# keyword arguments); older versions cannot mount the tab or assets. Check
# before loading sidekiq/web, which can itself fail to load on old versions.
if Gem::Version.new(::Sidekiq::VERSION) < Gem::Version.new("7.3")
  raise LoadError.new("patient_http/sidekiq/web requires sidekiq >= 7.3 (you have #{::Sidekiq::VERSION})")
end

require "sidekiq/web"

module PatientHttp
  module Sidekiq
    # Sidekiq Web UI extension that adds an Async HTTP tab to the dashboard.
    # Requires Sidekiq 7.3 or later.
    class WebUI
      # The directory that holds the extension's views, locales, and assets.
      ROOT = File.join(__dir__, "web_ui")

      # The directory that holds the extension's views.
      VIEWS = File.join(ROOT, "views")

      # The number of in-flight requests that the dashboard lists. The
      # dashboard lists the oldest requests, because those are the most likely
      # to need attention.
      INFLIGHT_LIMIT = 50

      class << self
        # Returns the ERB template for the dashboard page.
        #
        # Sidekiq versions before 8.1 resolve a symbol view name to a `.erb`
        # file, and later versions resolve it to a `.html.erb` file. Rendering
        # the template from a string works with every version.
        #
        # @return [String] The template source.
        def template
          @template ||= File.read(File.join(VIEWS, "patient_http.html.erb"))
        end

        # Builds the rows of the processor table on the dashboard. Each row
        # combines a processor's cumulative counters with the live capacity
        # that the processor reports.
        #
        # When only one processor is configured, per-processor stats aren't
        # recorded because they would duplicate the totals. In that case, this
        # method returns an empty Array.
        #
        # @param stats_by_processor [Hash, nil] The cumulative counters, keyed
        #   by processor name.
        # @param capacity_by_processor [Hash] The in-flight and capacity counts,
        #   keyed by processor name.
        # @return [Array<Hash>] One row for each processor, sorted by name.
        def processor_rows(stats_by_processor, capacity_by_processor)
          stats_by_processor ||= {}
          return [] if stats_by_processor.empty? && capacity_by_processor.size < 2

          names = (stats_by_processor.keys | capacity_by_processor.keys).sort
          names.map do |name|
            counts = stats_by_processor[name] || {}
            capacity = capacity_by_processor[name] || {}
            requests = counts["requests"].to_i
            max_capacity = capacity[:max_capacity].to_i
            inflight = capacity[:inflight].to_i

            {
              name: name,
              inflight: inflight,
              peak_inflight: counts["max_inflight"].to_i,
              max_capacity: max_capacity,
              utilization: (max_capacity > 0) ? (inflight.to_f / max_capacity * 100).round(1) : 0,
              requests: requests,
              errors: counts["errors"].to_i,
              max_capacity_exceeded: counts["max_capacity_exceeded"].to_i,
              avg_duration: (requests > 0) ? (counts["duration"].to_f / requests).round(3) : 0.0
            }
          end
        end

        # Adds the dashboard routes to the Sidekiq Web application.
        # Sidekiq::Web calls this method when it registers the extension.
        #
        # @param app [Class] The Sidekiq Web application.
        # @return [void]
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

            # Per-processor breakdown, combining the cumulative counters with
            # the capacity each processor reports.
            processors = PatientHttp::Sidekiq::WebUI.processor_rows(
              totals["processors"],
              PatientHttp::Sidekiq::TaskMonitor.inflight_counts_by_processor(processes)
            )

            # The requests that have been in flight the longest.
            inflight = PatientHttp::Sidekiq::TaskMonitor.inflight_details(limit: INFLIGHT_LIMIT)

            erb(PatientHttp::Sidekiq::WebUI.template, locals: {
              totals: totals,
              total_requests: total_requests,
              avg_duration: avg_duration,
              max_capacity: max_capacity,
              current_inflight: current_inflight,
              utilization: utilization,
              processes: processes,
              processors: processors,
              inflight: inflight
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

  register_options = {
    name: "patient-http",
    tab: "patient_http_tab",
    index: "patient-http",
    root_dir: PatientHttp::Sidekiq::WebUI::ROOT,
    asset_paths: ["css", "js"]
  }

  if ::Sidekiq::Web.respond_to?(:configure)
    ::Sidekiq::Web.configure do |config|
      if config.respond_to?(:register_extension)
        # Sidekiq 8.x yields a Sidekiq::Web::Config object
        config.register_extension(PatientHttp::Sidekiq::WebUI, **register_options)
      else
        # Sidekiq 7.3.5+ yields the Sidekiq::Web class, which only has register
        config.register(PatientHttp::Sidekiq::WebUI, **register_options)
      end
    end
  else
    # Sidekiq 7.3.0 - 7.3.4 has no Sidekiq::Web.configure
    ::Sidekiq::Web.register(PatientHttp::Sidekiq::WebUI, **register_options)
  end
end
