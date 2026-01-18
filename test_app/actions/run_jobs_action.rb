# frozen_string_literal: true

class RunJobsAction
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
      StatusReport.new("AsynchronousWorker").reset!
      StatusReport.new("SynchronousWorker").reset!
    end

    # Build the base test URL for this application
    port = ENV.fetch("PORT", "9292")
    base_url = "http://localhost:#{port}/test"

    workers = []
    async_count.times { workers << AsynchronousWorker }
    sync_count.times { workers << SynchronousWorker }
    workers.shuffle.each do |worker|
      actual_delay = delay
      if delay > 0 && delay_drift > 0
        drift_fraction = delay_drift / 100.0
        lower_bound = delay * (1.0 - drift_fraction)
        upper_bound = delay * (1.0 + drift_fraction)
        actual_delay = rand(lower_bound..upper_bound)
      end

      url = "#{base_url}?delay=#{actual_delay}"
      worker.perform_async("GET", url, timeout, actual_delay)
    end

    [204, {}, []]
  end

  private

  def method_not_allowed_response
    [405, {"Content-Type" => "text/plain"}, ["Method Not Allowed"]]
  end
end
