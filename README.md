# Sidekiq::AsyncHttp

[![Continuous Integration](https://github.com/bdurand/sidekiq-async_http/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/sidekiq-async_http/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/sidekiq-async_http.svg)](https://badge.fury.io/rb/sidekiq-async_http)

*Built for APIs that like to think.*

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

## Quick Start

### 1. Create a Worker with Callbacks

The simplest way to use this gem is to include `Sidekiq::AsyncHttp::Job` in your worker and define callbacks:

```ruby
class FetchDataWorker
  include Sidekiq::AsyncHttp::Job

  # Define callback for completed responses. The callback receives a Response object.
  # Note that this will be called for all HTTP responses, including 4xx and 5xx status codes.
  on_completion do |response|
    user_id = response.callback_args[:user_id]
    endpoint = response.callback_args[:endpoint]
    data = response.json
    User.find(user_id).update!(external_data: data)
  end

  # Define callback for errors (optional). The callback receives an Error object.
  # This is only called if an error was raised during the HTTP request
  # (timeout, connection failure, etc).
  on_error do |error|
    user_id = error.callback_args[:user_id]
    endpoint = error.callback_args[:endpoint]
    Rails.logger.error("Failed to fetch #{endpoint} for user #{user_id}: #{error.message}")
  end

  def perform(user_id, endpoint)
    # This returns immediately after enqueueing the HTTP request. The callback args
    # will be available in the callbacks.
    async_get(
      "https://api.example.com/#{endpoint}",
      callback_args: {user_id: user_id, endpoint: endpoint}
    )
  end
end
```

> [!NOTE]
> The request should be the last thing your worker does.

### 2. That's It!

The processor starts automatically with Sidekiq. When the HTTP request completes, your `on_completion` will be executed as a new Sidekiq job with the [response](Sidekiq::AsyncHttp::Response) object.

If an error is raised during the request, the `on_error` callback will be executed instead with the [error](Sidekiq::AsyncHttp::Error) information.

The `response.callback_args` and `error.callback_args` provide access to the arguments you passed via the `callback_args:` option. You can access them using symbol or string keys:

```ruby
response.callback_args[:user_id]    # Symbol access
response.callback_args["user_id"]   # String access
```

> [!IMPORTANT]
> Do not re-raise the error as a mechanism in the error callback as a means to retry the job. That will just result in the error callback job being retried instead. If you want to retry the original job from an `on_error` callback, you can call `perform_in` or `perform_async` from within the `on_error` callback. Be careful with this approach, though, as it can lead to infinite retry loops if the error condition is not resolved.
>
> Also note that the error callback is only called when an exception is raised during the HTTP request (timeout, connection failure, etc). HTTP error status codes (4xx, 5xx) do not trigger the error callback. Instead, they are treated as completed requests and passed to the `on_completion` callback.

## Usage Patterns

### Using the Job Mixin (Recommended)

The `Sidekiq::AsyncHttp::Job` mixin provides a clean DSL for async HTTP requests:

```ruby
class ApiWorker
  include Sidekiq::AsyncHttp::Job

  # Configure a shared HTTP client with base URL and default headers
  async_http_client base_url: "https://api.example.com",
                    headers: {"Authorization" => "Bearer #{ENV['API_KEY']}"},
                    timeout: 60

  # Callbacks receive the response/error object with callback_args
  on_completion do |response|
    resource_type = response.callback_args[:resource_type]
    resource_id = response.callback_args[:resource_id]

    if response.success?
      process_data(response.json, resource_type, resource_id)
    else
      handle_api_error(response.status, resource_type, resource_id)
    end
  end

  on_error do |error|
    resource_type = error.callback_args[:resource_type]
    resource_id = error.callback_args[:resource_id]

    case error.error_type
    when :timeout
      # Re-enqueue with exponential backoff
      ApiWorker.perform_in(5.minutes, resource_type, resource_id)
    when :connection
      notify_ops_team("API connection failure", error)
    end
  end

  def perform(resource_type, resource_id)
    # Uses the configured client and passes callback arguments
    async_get(
      "/#{resource_type}/#{resource_id}",
      callback_args: {resource_type: resource_type, resource_id: resource_id}
    )
  end
end
```

The job mixin can also be used with ActiveJob if the queue adapter is set to Sidekiq. If the queue adapter is not Sidekiq, the HTTP request will be executed synchronously, instead.

```ruby
class ActiveJobExample < ApplicationJob
  include Sidekiq::AsyncHttp::Job

  on_completion do |response|
    record_id = response.callback_args[:record_id]
    Record.find(record_id).update!(data: response.json)
  end

  on_error do |error|
    record_id = error.callback_args[:record_id]
    Rails.logger.error("Failed to fetch record #{record_id}: #{error.message}")
  end

  def perform(record_id)
    async_get(
      "https://api.example.com/records/#{record_id}",
      callback_args: {record_id: record_id}
    )
  end
end
```

### Defining Your Own Callback Workers

For more complex workflows callbacks, you can define dedicated Sidekiq workers for completion and error handling.

The `perform` methods of these workers will receive the response or error object as a single argument. You can access callback arguments via `response.callback_args` or `error.callback_args`:

```ruby
# Define dedicated callback workers
class FetchCompletionWorker
  include Sidekiq::Job
  sidekiq_options queue: "critical", retry: 10

  def perform(response)
    user_id = response.callback_args[:user_id]
    User.find(user_id).update!(data: response.json)
  end
end

class FetchErrorWorker
  include Sidekiq::Job
  sidekiq_options queue: "low"

  def perform(error)
    user_id = error.callback_args[:user_id]
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
    async_get(
      "https://api.example.com/users/#{user_id}",
      callback_args: {user_id: user_id}
    )
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

### Callback Arguments

Callback workers receive a single Response or Error object as an argument. You can pass custom data to your callbacks using the `callback_args` option. This data will be accessible via `response.callback_args` or `error.callback_args`:

```ruby
class FetchUserDataWorker
  include Sidekiq::AsyncHttp::Job

  on_completion do |response|
    # Access callback_args using symbol or string keys
    user_id = response.callback_args[:user_id]
    request_timestamp = response.callback_args[:request_timestamp]

    User.find(user_id).update!(
      external_data: response.json,
      fetched_at: request_timestamp
    )
  end

  on_error do |error|
    user_id = error.callback_args[:user_id]
    request_timestamp = error.callback_args[:request_timestamp]

    Rails.logger.error(
      "Failed to fetch data for user #{user_id} at #{request_timestamp}: #{error.message}"
    )
  end

  def perform(user_id, options = {})
    # Pass data via callback_args option
    timestamp = Time.now.iso8601

    async_get(
      "https://api.example.com/users/#{user_id}",
      callback_args: {
        user_id: user_id,
        request_timestamp: timestamp
      }
    )
  end
end
```

**Important details about callback_args:**

- Must be a Hash (or respond to `to_h`) containing only JSON-native types: `nil`, `true`, `false`, `String`, `Integer`, `Float`, `Array`, or `Hash`
- Hash keys will be converted to strings for serialization
- Nested hashes and hashes in arrays also have their keys converted to strings
- You can access callback_args using either symbol or string keys: `callback_args[:user_id]` or `callback_args["user_id"]`

This is useful when:
- Your original job arguments contain data not needed by the callback
- You want to pass computed values from the original job to the callback
- You need to pass additional context about when/why the request was made

You can also use it when calling `Request#execute` directly:

```ruby
request.execute(
  completion_worker: MyCompletionWorker,
  error_worker: MyErrorWorker,
  callback_args: {user_id: 123, action: "fetch"}
)
```

### Sensitive Data Handling

Responses from asynchronous HTTP requests will be pushed to Redis in order to call the completion job. This can raise security concerns if the response contains sensitive data since the data will be stored in plain text.

You can use the with the [sidekiq-encrypted_args](https://github.com/bdurand/sidekiq-encrypted_args) gem to encrypt the response data before it is stored in Redis.

First, setup the encryption configuration in an initializer. You'll also need to append the `Sidekiq::AsyncHttp` middleware so that it comes after the decryption middleware inserted by calling `Sidekiq::EncryptedArgs.configure!`:

```ruby
Sidekiq::EncryptedArgs.configure!(secret: "YourSecretKey")
Sidekiq::AsyncHttp.append_middleware
```

Next, specify the `encrypted_args` option in the `on_completion` callback to indicate the response argument should be encrypted:

```ruby
class SensitiveDataWorker
  include Sidekiq::AsyncHttp::Job

  on_completion(encrypted_args: :response) do |response, record_id|
    SensitiveRecord.find(record_id).update!(data: response.body)
  end

  on_error do |error, record_id|
    Rails.logger.error("Failed to fetch sensitive data for record #{record_id}: #{error.message}")
  end

  def perform(record_id)
    async_get("https://secure-api.example.com/data/#{record_id}")
  end
end
```

> [!NOTE]
> You can only encrypt the response argument by name with the `encrypted_args` option when using `on_completion`. If you need to encrypt other arguments, you can either pass `true` to encrypt all arguments or pass an array of the indexes of the arguments to encrypt. See the [sidekiq-encrypted_args documentation](https://github.com/bdurand/sidekiq-encrypted_args) for more details.

> [!NOTE]
> The encryption feature in Sidekiq Enterprise will not work for this because it can only be applied to a single hash argument that must be the last argument to the job.

## Configuration

The gem can be configured globally in an initializer:

```ruby
# config/initializers/sidekiq_async_http.rb
Sidekiq::AsyncHttp.configure do |config|
  # Maximum concurrent HTTP requests (default: 256)
  config.max_connections = 256

  # Default timeout for HTTP requests in seconds (default: 60)
  config.default_request_timeout = 60

  # Default User-Agent header for all requests (optional)
  config.user_agent = "MyApp/1.0"

  # Timeout for graceful shutdown in seconds (default: the Sidekiq
  # shutdown timeout minus 2 seconds). This should be less than Sidekiq's
  # shutdown timeout
  config.shutdown_timeout = 23

  # Maximum response body size in bytes (default: 1MB)
  # Responses larger than this will trigger ResponseTooLargeError
  config.max_response_size = 1024 * 1024

  # Idle connection timeout in seconds (default: 60)
  config.idle_connection_timeout = 60

  # Heartbeat interval for crash recovery in seconds (default: 60)
  config.heartbeat_interval = 60

  # Orphan detection threshold in seconds (default: 300)
  # Requests older than this without a heartbeat will be re-enqueued
  config.orphan_threshold = 300

  # Custom logger (defaults to Sidekiq.logger)
  config.logger = Rails.logger
end
```

See the [Sidekiq::AsyncHttp::Configuration](Sidekiq::AsyncHttp::Configuration) documentation for all available options.

### Tuning Tips

- `max_connections`: Adjust this based on your system's resources. Each connection uses memory and file descriptors. A tuned system with sufficient resources can handle thousands of concurrent connections.
- `default_request_timeout`: Set this based on the expected response times of the APIs you are calling. AI APIs might sometimes take minutes to respond as they generate content.
- `max_response_size`: Set this to limit the maximum size of HTTP responses. This helps prevent excessive memory usage from unexpectedly large responses. Responses need to be serialized to Redis as Sidekiq jobs and very large responses may cause performance issues in Redis. If a response body is text content, it will be compressed to save space in Redis. However, binary content needs to be Base64 encoded which increases size by ~33%.

> [!IMPORTANT]
>
> One difference between using this gem and making synchronous HTTP requests from a Sidekiq job is that the if `max_connections` is reached due to slow asynchronous requests, new requests will trigger an error on the Sidekiq Job. The Sidekiq retry mechanism will handle re-enqueuing the job.
>
> In contrast, slow synchronous HTTP requests will fill up the Sidekiq worker pool and block new jobs from being dequeued until a worker thread becomes free.
>
> In general, the former behavior is preferable because it allows Sidekiq to continue processing other jobs and prevents getting into a state with 1000's of jobs stuck in the queue.

## Metrics and Monitoring

### Web UI

If you're using Sidekiq's Web UI, you can add a tab with the async HTTP processor statistics:

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

> [!NOTE]
> These callbacks are not available when using through the ActiveJob interface.

## Shutdown Behavior

The async HTTP processor automatically hooks in with Sidekiq's lifecycle events.

1. **Startup:** Processor starts automatically when Sidekiq starts
2. **Quiet (TSTP signal):** Processor stops accepting new requests but continues processing in-flight requests
3. **Shutdown:** Processor waits up to `shutdown_timeout` seconds for in-flight requests to complete

### Incomplete Request Handling

If requests are still in-flight when shutdown times out:

- In-flight requests are interrupted
- The **original Sidekiq job** is automatically re-enqueued
- Re-enqueued jobs will be processed again when Sidekiq restarts

This ensures no work is lost during deployments or restarts.

### Crash Recovery

The gem includes crash recovery to handle process failures:

1. **Heartbeat Tracking:** Every `heartbeat_interval` seconds, the processor updates heartbeat timestamps for all in-flight requests in Redis
2. **Orphan Detection:** One processor periodically checks for requests that haven't received a heartbeat update in `orphan_threshold` seconds
3. **Automatic Re-enqueue:** Orphaned requests have their original Sidekiq jobs re-enqueued

This ensures that if a Sidekiq process crashes, its in-flight requests will be retried by another process.

## Testing

The gem supports `Sidekiq::Testing.inline!` mode for synchronous testing. When in inline mode, async HTTP requests are executed immediately within the worker thread, blocking until completion. This allows you to write tests that verify the full request/response cycle without needing the async processor to be running.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "sidekiq-async_http"
```

Then execute:

```bash
bundle install
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/sidekiq-async_http).

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

Running the tests requires a Redis compatible server. There is a script to start one in a local container running on port 24455:

```bash
bin/run-valkey
```

Then run the test suite with:

```bash
bundle exec rake
```

There is also a bundled test app in the `test_app` directory that can be used for manual testing and experimentation.

To run the test app, first install the dependencies:

```bash
bundle exec rake test_app:bundle
```

The server will run on http://localhost:9292 and can be started with:

```bash
bundle exec rake test_app
```



## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
