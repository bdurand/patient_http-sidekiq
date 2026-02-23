# frozen_string_literal: true

class RunJobsAction
  include PatientHttp::RequestHelper

  BASE_URL = "http://localhost:#{ENV.fetch("PORT", "9292")}"

  request_template base_url: BASE_URL

  def call(env)
    request = Rack::Request.new(env)
    return method_not_allowed_response unless request.post?

    async_count = request.params["async_count"].to_i.clamp(0, 5000)
    sync_count = request.params["sync_count"].to_i.clamp(0, 5000)
    delay = request.params["delay"].to_f
    timeout = request.params["timeout"].to_f
    delay_drift = request.params["delay_drift"].to_f.clamp(0.0, 100.0)

    # Reset success and error counters only if all activity is zero
    current_stats = CurrentStats.new
    if current_stats.no_activity?
      StatusReport.new("Asynchronous").reset!
      StatusReport.new("Synchronous").reset!
    end

    drifted_delay = lambda do
      actual_delay = delay
      if delay > 0 && delay_drift > 0
        drift_fraction = delay_drift / 100.0
        lower_bound = delay * (1.0 - drift_fraction)
        upper_bound = delay * (1.0 + drift_fraction)
        actual_delay = rand(lower_bound..upper_bound).round(6)
      end
      actual_delay
    end

    jobs = []
    async_count.times do
      jobs << lambda { async_get("/slow", params: {delay: drifted_delay.call}, callback: StatusReport::Callback, timeout: timeout) }
    end

    sync_count.times do
      jobs << lambda { SynchronousWorker.perform_async("GET", "#{BASE_URL}/slow?delay=#{drifted_delay.call}", timeout) }
    end
    jobs.shuffle.each(&:call)

    [204, {}, []]
  end

  private

  def method_not_allowed_response
    [405, {"Content-Type" => "text/plain"}, ["Method Not Allowed"]]
  end
end
