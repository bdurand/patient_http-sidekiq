# frozen_string_literal: true

# Worker that fires asynchronous HTTP requests from inside a Sidekiq job so the
# requests originate on the Sidekiq server rather than in a web request.
class EnqueueRequestsWorker
  include Sidekiq::Job
  include PatientHttp::RequestHelper

  BASE_URL = "http://localhost:#{ENV.fetch("PORT", "9292")}"

  request_template base_url: BASE_URL

  def perform(count, delay, timeout, delay_drift, processor = nil)
    count.times do
      async_get(
        "/slow",
        params: {delay: drifted_delay(delay, delay_drift)},
        callback: StatusReport::Callback,
        timeout: timeout,
        processor: processor
      )
    end
  end

  private

  def drifted_delay(delay, delay_drift)
    return delay unless delay > 0 && delay_drift > 0

    drift_fraction = delay_drift / 100.0
    lower_bound = delay * (1.0 - drift_fraction)
    upper_bound = delay * (1.0 + drift_fraction)
    rand(lower_bound..upper_bound).round(6)
  end
end
