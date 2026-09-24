# frozen_string_literal: true

# Configuration for patient_http running on Sidekiq.
#
# Every option below is optional and shown with its default. The gem works with
# no configuration at all: requiring it registers the request handler, and the
# async processor starts and stops with your Sidekiq server.
#
# Make requests from anywhere in your application:
#
#   PatientHttp.get("https://api.example.com/users/1",
#     callback: FetchUserCallback,
#     callback_args: {user_id: 1})
#
# Full reference: https://github.com/bdurand/patient_http-sidekiq#configuration

PatientHttp.configure do |config|
  # --- HTTP behavior -------------------------------------------------------

  # Maximum concurrent HTTP requests per process.
  # config.max_connections = 256

  # Default request timeout in seconds. Raise it for slow APIs; LLM APIs can
  # take minutes.
  # config.request_timeout = 60

  # Cap sockets opened against any single host so one host cannot consume every
  # file descriptor. Unlimited by default.
  # config.max_connections_per_host = 32

  # Maximum response body size in bytes. Larger responses raise
  # PatientHttp::ResponseTooLargeError.
  # config.max_response_size = 1024 * 1024

  # Treat 4xx and 5xx responses as errors (routing them to the callback's
  # on_error) instead of delivering them to on_complete.
  # config.raise_error_responses = false

  # User-Agent sent with every request.
  # config.user_agent = "MyApp/1.0"

  # --- Sending sensitive values -------------------------------------------

  # Requests are serialized into Redis before they run. Register secrets by
  # name and reference them with PatientHttp.secret(:api_token) when building a
  # request; only the name is written to the queue, and the value is resolved
  # in the processor at send time.
  #
  # config.register_secret(:api_token) { ENV["API_TOKEN"] }

  # Encrypt request and response payloads in Redis. Pass an array of keys to
  # rotate: the first encrypts, all of them decrypt.
  #
  # config.encryption_key = Rails.application.credentials.patient_http_key

  # --- Large payloads ------------------------------------------------------

  # Payloads over the threshold are written to a payload store instead of being
  # passed through Redis. Register a store to turn this on.
  #
  # config.register_payload_store(:redis, adapter: :redis, redis: Redis.new, ttl: 86_400)
  # config.payload_store_threshold = 64 * 1024

  # --- Workload isolation --------------------------------------------------

  # Named processors run independently, each with its own capacity and
  # timeouts, so a burst of one kind of work cannot starve another. Route a
  # request with PatientHttp.get(url, callback: Cb, processor: :llm).
  #
  # config.processor(:llm, max_connections: 200, request_timeout: 120)
  # config.processor(:webhooks, max_connections: 64, request_timeout: 10)

  # --- Sidekiq specifics ---------------------------------------------------

  # Sidekiq options applied to this gem's request and callback jobs.
  # config.sidekiq_options = {queue: "patient_http", retry: 5}

  # Graceful shutdown budget in seconds. Defaults to Sidekiq's own shutdown
  # timeout minus two seconds, and must stay below it.
  # config.shutdown_timeout = 23

  # Called when a callback job exhausts its Sidekiq retries.
  # config.on_retries_exhausted { |error| Sentry.capture_message(error.message) }
end

# Hooks for metrics. Both can be registered more than once.
#
# PatientHttp::Sidekiq.after_completion do |response|
#   StatsD.timing("patient_http.duration", response.duration * 1000)
# end
#
# PatientHttp::Sidekiq.after_error do |error|
#   StatsD.increment("patient_http.error")
# end
