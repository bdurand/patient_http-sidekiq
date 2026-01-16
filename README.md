# Sidekiq::AsyncHttp

[![Continuous Integration](https://github.com/bdurand/sidekiq-async_http/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/sidekiq-async_http/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/sidekiq-async_http.svg)](https://badge.fury.io/rb/sidekiq-async_http)

__Built for APIs that like to think.__

This gem provides a mechanism to offload HTTP requests from Sidekiq jobs to a dedicated async I/O processor, freeing worker threads immediately.

## Motivation

Sidekiq is designed with the assumption that jobs are short-lived and complete quickly. Long-running HTTP requests block worker threads from processing other jobs, leading to increased latency and reduced throughput. This is particularly problematic when calling LLM or AI APIs, where requests can take many seconds to complete.

**The Problem:**

```
┌────────────────────────────────────────────────────────────────────────┐
│                     Traditional Sidekiq Job                            │
│                                                                        │
│  Worker Thread 1: [████████████ HTTP Request (5s) ████████████████]    │
│  Worker Thread 2: [████████████ HTTP Request (5s) ████████████████]    │
│  Worker Thread 3: [████████████ HTTP Request (5s) ████████████████]    │
│                                                                        │
│  → 3 workers blocked for 5 seconds = 0 jobs processed                  │
└────────────────────────────────────────────────────────────────────────┘
```

**The Solution:**

```
┌────────────────────────────────────────────────────────────────────────┐
│                     With Async HTTP Processor                          │
│                                                                        │
│  Worker Thread 1: [█ Enqueue █][█ Job █][█ Job █][█ Job █][█ Job █]    │
│  Worker Thread 2: [█ Enqueue █][█ Job █][█ Job █][█ Job █][█ Job █]    │
│  Worker Thread 3: [█ Enqueue █][█ Job █][█ Job █][█ Job █][█ Job █]    │
│                                                                        │
│  Async Processor: [═══════════ 100+ concurrent HTTP requests ════════] │
│                                                                        │
│  → Workers immediately free = dozens of jobs processed                 │
└────────────────────────────────────────────────────────────────────────┘
```

The async processor runs in a dedicated thread within your Sidekiq process, using Ruby's Fiber-based concurrency to handle hundreds of concurrent HTTP requests without blocking. When an HTTP request completes, the response is passed to a callback worker for processing.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "sidekiq-async_http"
```

Then execute:

```bash
bundle install
```

## Requirements

- Ruby 3.2 or higher
- Sidekiq 7.2 or higher

## Quick Start

### 1. Create a Worker with Callbacks

The simplest way to use this gem is to include `Sidekiq::AsyncHttp::Job` in your worker and define callbacks:

```ruby
class FetchDataWorker
  include Sidekiq::AsyncHttp::Job

  # Define callback for successful responses
  on_completion do |response, user_id, endpoint|
    data = response.json
    User.find(user_id).update!(external_data: data)
  end

  # Define callback for errors (optional)
  on_error do |error, user_id, endpoint|
    Rails.logger.error("Failed to fetch data for user #{user_id}: #{error.message}")
    # Error will be retried automatically if no on_error is defined
  end

  def perform(user_id, endpoint)
    # This returns immediately after enqueueing the HTTP request
    async_get("https://api.example.com/#{endpoint}")
  end
end
```

> [!NOTE]
> The request should be the last thing your worker does.

### 2. That's It!

The processor starts automatically with Sidekiq. When the HTTP request completes, your `on_completion` or `on_error` will be executed as a new Sidekiq job with the original arguments.

## Usage Patterns

### Using the Job Mixin (Recommended)

The `Sidekiq::AsyncHttp::Job` mixin provides a clean DSL for async HTTP requests:

```ruby
class ApiWorker
  include Sidekiq::AsyncHttp::Job

  # Configure a shared HTTP client with base URL and default headers
  client base_url: "https://api.example.com",
         headers: {"Authorization" => "Bearer #{ENV['API_KEY']}"},
         timeout: 60

  # Callbacks receive the response/error plus original job arguments
  on_completion do |response, resource_type, resource_id|
    if response.success?
      process_data(response.json, resource_type, resource_id)
    else
      handle_api_error(response.status, resource_type, resource_id)
    end
  end

  on_error do |error, resource_type, resource_id|
    case error.error_type
    when :timeout
      # Re-enqueue with exponential backoff
      ApiWorker.perform_in(5.minutes, resource_type, resource_id)
    when :connection
      notify_ops_team("API connection failure", error)
    end
  end

  def perform(resource_type, resource_id)
    # Uses the configured client
    async_get("/#{resource_type}/#{resource_id}")
  end
end
```

### Making Different Types of Requests

```ruby
class WebhookWorker
  include Sidekiq::AsyncHttp::Job

  on_completion { |response, event_id| WebhookDelivery.mark_delivered(event_id) }
  on_error { |error, event_id| WebhookDelivery.mark_failed(event_id, error.message) }

  def perform(event_id)
    event = Event.find(event_id)
    webhook = event.webhook

    # POST with JSON body
    async_post(
      webhook.url,
      json: event.payload,
      headers: {"X-Webhook-Signature" => sign_payload(event.payload, webhook.secret)},
      timeout: 30
    )
  end
end
```

### Using Separate Callback Workers

For more complex workflows or when you need different Sidekiq options for callbacks:

```ruby
# Define dedicated callback workers
class FetchCompletionWorker
  include Sidekiq::Job
  sidekiq_options queue: "critical", retry: 10

  def perform(response_data, user_id)
    response = Sidekiq::AsyncHttp::Response.from_h(response_data)
    User.find(user_id).update!(data: response.json)
  end
end

class FetchErrorWorker
  include Sidekiq::Job
  sidekiq_options queue: "low"

  def perform(error_data, user_id)
    error = Sidekiq::AsyncHttp::Error.from_h(error_data)
    ErrorTracker.record(error, user_id: user_id)
  end
end

# Use them in your worker
class FetchUserDataWorker
  include Sidekiq::AsyncHttp::Job

  # Point to dedicated callback workers
  self.completion_callback_worker = FetchCompletionWorker
  self.error_callback_worker = FetchErrorWorker

  def perform(user_id)
    async_get("https://api.example.com/users/#{user_id}")
  end
end
```

### Using the Client Directly

For more control, you can use the `Sidekiq::AsyncHttp::Client` directly:

```ruby
class FlexibleWorker
  include Sidekiq::Job

  def perform(url, method, data = nil)
    client = Sidekiq::AsyncHttp::Client.new(
      timeout: 120,
      connect_timeout: 10,
      headers: {"User-Agent" => "MyApp/1.0"}
    )

    request = client.async_request(method.to_sym, url, json: data)
    request.execute(
      completion_worker: DataProcessorWorker,
      error_worker: ErrorHandlerWorker
    )
  end
end
```

## Response Object

The `Sidekiq::AsyncHttp::Response` object passed to your success callback includes:

```ruby
on_completion do |response, *args|
  response.status      # => 200 (Integer)
  response.headers     # => HttpHeaders object (hash-like, case-insensitive)
  response.body        # => Response body as String
  response.json        # => Parsed JSON (raises if not JSON content-type)
  response.duration    # => Request duration in seconds (Float)
  response.url         # => The request URL
  response.method      # => The HTTP method (:get, :post, etc.)
  response.protocol    # => "HTTP/1.1" or "HTTP/2"
  response.request_id  # => Unique request identifier (UUID)

  # Status helpers
  response.success?      # => true for 2xx status
  response.redirect?     # => true for 3xx status
  response.client_error? # => true for 4xx status
  response.server_error? # => true for 5xx status
  response.error?        # => true for 4xx or 5xx status
end
```

## Error Object

The `Sidekiq::AsyncHttp::Error` object passed to your error callback includes:

```ruby
on_error do |error, *args|
  error.class_name   # => "Async::TimeoutError" (String)
  error.message      # => Error message
  error.backtrace    # => Array of backtrace lines
  error.error_type   # => :timeout, :connection, :ssl, :protocol, :response_too_large, or :unknown
  error.duration     # => How long the request ran before failing
  error.url          # => The request URL
  error.method       # => The HTTP method
  error.request_id   # => Unique request identifier (UUID)
end
```

**Note:** The `Error` object represents exceptions that occurred during the HTTP request (timeouts, connection failures, SSL errors). HTTP error responses (4xx, 5xx) are delivered to the `on_completion` as a `Response` object with an error status code.

## Configuration

Configure the gem in an initializer:

```ruby
# config/initializers/sidekiq_async_http.rb
Sidekiq::AsyncHttp.configure do |config|
  # Maximum concurrent HTTP requests (default: 256)
  config.max_connections = 256

  # Default timeout for HTTP requests in seconds (default: 60)
  config.default_request_timeout = 60

  # Timeout for graceful shutdown in seconds (default: 25)
  # Should be less than Sidekiq's shutdown timeout
  config.shutdown_timeout = 25

  # Maximum response body size in bytes (default: 10MB)
  # Responses larger than this will trigger ResponseTooLargeError
  config.max_response_size = 10 * 1024 * 1024

  # Idle connection timeout in seconds (default: 60)
  config.idle_connection_timeout = 60

  # DNS cache TTL in seconds (default: 300)
  config.dns_cache_ttl = 300

  # Heartbeat interval for crash recovery in seconds (default: 60)
  config.heartbeat_interval = 60

  # Orphan detection threshold in seconds (default: 300)
  # Requests older than this without a heartbeat will be re-enqueued
  config.orphan_threshold = 300

  # Default User-Agent header for all requests (optional)
  config.user_agent = "MyApp/1.0"

  # Custom logger (defaults to Sidekiq.logger)
  config.logger = Rails.logger
end
```

### Configuration Options Reference

| Option | Default | Description |
|--------|---------|-------------|
| `max_connections` | 256 | Maximum concurrent HTTP requests per Sidekiq process |
| `default_request_timeout` | 60 | Default timeout in seconds for HTTP requests |
| `shutdown_timeout` | 25 | Maximum time to wait for in-flight requests during shutdown |
| `max_response_size` | 10MB | Maximum allowed response body size |
| `idle_connection_timeout` | 60 | Time before idle connections are closed |
| `dns_cache_ttl` | 300 | How long to cache DNS lookups |
| `heartbeat_interval` | 60 | Interval for updating request heartbeats in Redis |
| `orphan_threshold` | 300 | Age threshold for detecting orphaned requests |
| `user_agent` | nil | Default User-Agent header for all requests |
| `logger` | Sidekiq.logger | Logger instance for debug/error output |

## Metrics and Monitoring

### Accessing Metrics

```ruby
# Get current metrics
metrics = Sidekiq::AsyncHttp.metrics

metrics.inflight_count   # Current number of requests in flight
metrics.total_requests   # Total requests processed since startup
metrics.average_duration # Average request duration in seconds
metrics.error_count      # Total errors since startup
metrics.errors_by_type   # Hash of error type => count

# Get a complete snapshot
metrics.to_h
# => {
#   "inflight_count" => 5,
#   "total_requests" => 1234,
#   "average_duration" => 0.45,
#   "error_count" => 12,
#   "errors_by_type" => { timeout: 8, connection: 4 },
#   "refused_count" => 0
# }
```

### Redis-Backed Statistics

Aggregate statistics across all Sidekiq processes are stored in Redis:

```ruby
stats = Sidekiq::AsyncHttp::Stats.instance

stats.get_totals
# => {
#   "requests" => 50000,
#   "duration" => 22500.5,
#   "errors" => 150,
#   "refused" => 0
# }

stats.get_total_inflight      # Total in-flight requests across all processes
stats.get_total_max_connections # Total capacity across all processes
```

### Web UI

If you're using Sidekiq's Web UI, the gem automatically adds an "Async HTTP" tab:

```ruby
# config/routes.rb (Rails)
require "sidekiq/web"
require "sidekiq/async_http/web_ui"

mount Sidekiq::Web => "/sidekiq"
```

The Web UI shows:
- Total requests, errors, and average duration
- Current capacity utilization
- Per-process inflight request counts

### Callbacks for Custom Monitoring

You can register callbacks to integrate with your monitoring system using the `after_completion` and `after_error` hooks:

```ruby
Sidekiq::AsyncHttp.after_completion do |response|
  StatsD.timing("async_http.duration", response.duration * 1000)
  StatsD.increment("async_http.status.#{response.status}")
end

Sidekiq::AsyncHttp.after_error do |error|
  StatsD.increment("async_http.error.#{error.error_type}")
  Sentry.capture_message("Async HTTP error: #{error.message}")
end
```

You can register multiple callbacks; they will be called in the order registered.

## Shutdown Behavior

The async HTTP processor integrates with Sidekiq's lifecycle:

1. **Startup:** Processor starts automatically when Sidekiq starts
2. **Quiet (TSTP signal):** Processor stops accepting new requests but continues processing in-flight requests
3. **Shutdown:** Processor waits up to `shutdown_timeout` seconds for in-flight requests to complete

### Incomplete Request Handling

If requests are still in-flight when shutdown times out:

- In-flight requests are interrupted
- The **original Sidekiq job** is automatically re-enqueued
- Re-enqueued jobs will be processed again when Sidekiq restarts

This ensures no work is lost during deployments or restarts.

## Crash Recovery

The gem includes crash recovery to handle process failures:

1. **Heartbeat Tracking:** Every `heartbeat_interval` seconds, the processor updates heartbeat timestamps for all in-flight requests in Redis
2. **Orphan Detection:** One processor periodically checks for requests that haven't received a heartbeat update in `orphan_threshold` seconds
3. **Automatic Re-enqueue:** Orphaned requests have their original Sidekiq jobs re-enqueued

This ensures that if a Sidekiq process crashes, its in-flight requests will be retried by another process.

## Connection Pooling and Tuning

### How Connection Pooling Works

The gem uses [async-http](https://github.com/socketry/async-http) which provides:

- Automatic HTTP/1.1 keep-alive connection reuse
- HTTP/2 multiplexing (multiple requests over a single connection)
- Intelligent connection management per host

### Tuning for Your Workload

**High-throughput APIs (many requests to few hosts):**

```ruby
Sidekiq::AsyncHttp.configure do |config|
  config.max_connections = 500        # Higher concurrency
  config.idle_connection_timeout = 120 # Keep connections alive longer
  config.dns_cache_ttl = 600          # Cache DNS longer
end
```

**Many different hosts (webhooks, diverse APIs):**

```ruby
Sidekiq::AsyncHttp.configure do |config|
  config.max_connections = 200        # Moderate concurrency
  config.idle_connection_timeout = 30 # Release idle connections faster
  config.dns_cache_ttl = 60           # Fresher DNS for diverse hosts
end
```

**Long-running requests (LLM/AI APIs):**

```ruby
Sidekiq::AsyncHttp.configure do |config|
  config.max_connections = 100        # Lower concurrency, longer requests
  config.default_request_timeout = 300 # 5 minute timeout
  config.shutdown_timeout = 60        # More time to complete during shutdown
end
```

## System Requirements

### File Descriptors

Each HTTP connection uses a file descriptor. Ensure your system limits are adequate:

```bash
# Check current limits
ulimit -n

# Increase for current session
ulimit -n 65536

# Permanent increase (add to /etc/security/limits.conf)
* soft nofile 65536
* hard nofile 65536
```

**Rule of thumb:** Set file descriptor limit to at least 2x your `max_connections` plus headroom for other operations.

### Memory

Each fiber in the async processor uses approximately 2-4KB of memory. With 256 concurrent requests:

- Fiber overhead: ~1MB
- Response buffering: Varies based on response sizes
- Connection state: ~100KB

For `max_response_size` of 10MB with 256 concurrent requests, worst case memory for responses is ~2.5GB. Adjust `max_response_size` based on your expected response sizes.

## Troubleshooting

### Requests Not Being Processed

**Symptom:** `NotRunningError` when calling `execute()`

**Cause:** The async processor hasn't started yet

**Solutions:**
- Ensure you're running within a Sidekiq server process
- The processor starts automatically on Sidekiq startup
- In tests, use `Sidekiq::Testing.inline!` mode

### MaxCapacityError

**Symptom:** `MaxCapacityError: Cannot enqueue request: already at max capacity`

**Cause:** More concurrent requests than `max_connections` allows

**Solutions:**
- Increase `max_connections` in configuration
- Implement backpressure in your workers (check capacity before enqueueing)
- Consider if you actually need that many concurrent requests

### Timeouts

**Symptom:** Requests timing out frequently

**Solutions:**
- Increase `default_request_timeout` or pass `timeout:` to individual requests
- Check if the target API is actually slow
- Monitor `average_duration` metrics

### Response Too Large

**Symptom:** `ResponseTooLargeError`

**Solutions:**
- Increase `max_response_size` if large responses are expected
- Consider streaming responses for very large payloads
- Check if the API has pagination options

### Requests Not Retrying After Crash

**Symptom:** Requests lost after process crash

**Check:**
- Ensure `heartbeat_interval` < `orphan_threshold`
- Verify Redis connectivity
- Check logs for orphan detection messages

### Memory Growth

**Symptom:** Memory usage growing over time

**Solutions:**
- Reduce `max_connections` if not all capacity is needed
- Lower `max_response_size` to limit buffering
- Ensure response bodies aren't being held in memory after processing

## Testing

The gem supports `Sidekiq::Testing.inline!` mode for synchronous testing:

```ruby
# spec/rails_helper.rb or test setup
Sidekiq::Testing.inline!

# In your tests, HTTP requests will execute synchronously
# and callbacks will be invoked inline
RSpec.describe FetchDataWorker do
  it "processes the response" do
    stub_request(:get, "https://api.example.com/data")
      .to_return(status: 200, body: '{"key": "value"}')

    FetchDataWorker.perform_async("data")

    # Callback has already executed by this point
    expect(SomeModel.last.data).to eq({"key" => "value"})
  end
end
```

For more control, you can mock the processor:

```ruby
RSpec.describe MyWorker do
  before do
    allow(Sidekiq::AsyncHttp).to receive(:running?).and_return(true)
    allow(Sidekiq::AsyncHttp.processor).to receive(:enqueue)
  end

  it "enqueues an async request" do
    MyWorker.perform_async(args)

    expect(Sidekiq::AsyncHttp.processor).to have_received(:enqueue)
      .with(an_instance_of(Sidekiq::AsyncHttp::RequestTask))
  end
end
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/sidekiq-async_http).

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
