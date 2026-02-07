# Sidekiq::AsyncHttp

[![Continuous Integration](https://github.com/bdurand/sidekiq-async_http/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/sidekiq-async_http/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/sidekiq-async_http.svg)](https://badge.fury.io/rb/sidekiq-async_http)

*Built for APIs that like to think.*

This gem provides a mechanism to offload HTTP requests to a dedicated async I/O processor running in your Sidekiq process, freeing worker threads immediately while HTTP requests are in flight.

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

The async processor runs in a dedicated thread within your Sidekiq process, using Ruby's Fiber-based concurrency to handle hundreds of concurrent HTTP requests without blocking. When an HTTP request completes, a callback service is invoked for processing.

## Quick Start

### 1. Create a Callback Service

Define a callback service class with `on_complete` and `on_error` methods:

```ruby
class FetchDataCallback
  def on_complete(response)
    user_id = response.callback_args[:user_id]
    data = response.json
    User.find(user_id).update!(external_data: data)
  end

  def on_error(error)
    user_id = error.callback_args[:user_id]
    Rails.logger.error("Failed to fetch data for user #{user_id}: #{error.message}")
  end
end
```

### 2. Make HTTP Requests

Make HTTP requests from anywhere in your code using `Sidekiq::AsyncHttp`:

```ruby
Sidekiq::AsyncHttp.get(
  "https://api.example.com/users/#{user_id}",
  callback: FetchDataCallback,
  callback_args: {user_id: user_id}
)
```

### 3. That's It!

The processor starts automatically with Sidekiq. When the HTTP request completes, your callback's `on_complete` method is executed as a new Sidekiq job with the [Response](lib/sidekiq/async_http/response.rb) object.

If an error occurs during the request, the `on_error` method is called with an [Error](lib/sidekiq/async_http/error.rb) object.

The `response.callback_args` and `error.callback_args` provide access to the arguments you passed via the `callback_args:` option. You can access them using symbol or string keys:

```ruby
response.callback_args[:user_id]    # Symbol access
response.callback_args["user_id"]   # String access
```

> [!NOTE]
> HTTP requests are made asynchronously. Calling `Sidekiq::AsyncHttp.get` enqueues a Sidekiq job to make the request, so you can call it from anywhere in your code (Sidekiq workers, Rails controllers, background scripts, etc.).

> [!IMPORTANT]
> Do not re-raise errors in the `on_error` callback as a means to retry. That will just retry the error callback job. If you want to retry the original request, you can enqueue a new request from within `on_error`. Be careful with this approach, though, as it can lead to infinite retry loops if the error condition is not resolved.
>
> Also note that the error callback is only called when an exception occurs during the HTTP request (timeout, connection failure, etc). HTTP error status codes (4xx, 5xx) do not trigger the error callback by default. Instead, they are treated as completed requests and passed to the `on_complete` callback. See the "Handling HTTP Error Responses" section below for how to treat HTTP errors as exceptions.

### Handling HTTP Error Responses

By default, HTTP error status codes (4xx, 5xx) are treated as successful responses and passed to the `on_complete` callback. You can check the status using `response.success?`, `response.client_error?`, or `response.server_error?`:

```ruby
class ApiCallback
  def on_complete(response)
    if response.success?
      process_data(response.json)
    elsif response.client_error?
      handle_client_error(response.status, response.body)
    elsif response.server_error?
      handle_server_error(response.status, response.body)
    end
  end

  def on_error(error)
    Rails.logger.error("Request failed: #{error.message}")
  end
end

Sidekiq::AsyncHttp.get(
  "https://api.example.com/data/#{id}",
  callback: ApiCallback
)
```

If you prefer to treat HTTP errors as exceptions, you can use the `raise_error_responses` option. When enabled, non-2xx responses will call the `on_error` callback with an `HttpError` instead:

```ruby
class ApiCallback
  def on_complete(response)
    # Only called for 2xx responses
    process_data(response.json)
  end

  def on_error(error)
    # Called for exceptions AND HTTP errors when using raise_error_responses
    if error.is_a?(Sidekiq::AsyncHttp::HttpError)
      # Access the response via error.response
      Rails.logger.error("HTTP #{error.status} from #{error.url}: #{error.response.body}")
    else
      # Regular request errors (timeout, connection, etc)
      Rails.logger.error("Request failed: #{error.message}")
    end
  end
end

Sidekiq::AsyncHttp.get(
  "https://api.example.com/data/#{id}",
  callback: ApiCallback,
  raise_error_responses: true
)
```

The `HttpError` provides convenient access to the response:

```ruby
def on_error(error)
  if error.is_a?(Sidekiq::AsyncHttp::HttpError)
    puts error.status              # HTTP status code
    puts error.url                 # Request URL
    puts error.http_method         # HTTP method
    puts error.response.body       # Response body
    puts error.response.headers    # Response headers
    puts error.response.json       # Parse JSON response (if applicable)
  end
end
```

## Usage Patterns

### Making Requests with Sidekiq::AsyncHttp

The main entry point is the `Sidekiq::AsyncHttp` module, which provides convenience methods for all HTTP verbs:

```ruby
# GET request
Sidekiq::AsyncHttp.get(
  "https://api.example.com/users/123",
  callback: MyCallback,
  callback_args: {user_id: 123}
)

# POST request with JSON body
Sidekiq::AsyncHttp.post(
  "https://api.example.com/users",
  callback: MyCallback,
  json: {name: "John", email: "john@example.com"}
)

# PUT request
Sidekiq::AsyncHttp.put(
  "https://api.example.com/users/123",
  callback: MyCallback,
  json: {name: "Updated Name"}
)

# PATCH request
Sidekiq::AsyncHttp.patch(
  "https://api.example.com/users/123",
  callback: MyCallback,
  json: {status: "active"}
)

# DELETE request
Sidekiq::AsyncHttp.delete(
  "https://api.example.com/users/123",
  callback: MyCallback
)
```

Available options:

- `callback:` - (required) Callback service class or class name
- `callback_args:` - Hash of arguments passed to callback via response/error
- `headers:` - Request headers
- `body:` - Request body (for POST/PUT/PATCH)
- `json:` - Object to serialize as JSON body (cannot use with body)
- `timeout:` - Request timeout in seconds
- `raise_error_responses:` - Treat non-2xx responses as errors

### Using Request Templates

For repeated requests to the same API, use `Sidekiq::AsyncHttp::RequestTemplate` to share configuration:

```ruby
class ApiService
  def initialize
    @template = Sidekiq::AsyncHttp::RequestTemplate.new(
      base_url: "https://api.example.com",
      headers: {"Authorization" => "Bearer #{ENV['API_KEY']}"},
      timeout: 60
    )
  end

  def fetch_user(user_id)
    request = @template.get("/users/#{user_id}")
    Sidekiq::AsyncHttp.execute(
      request,
      callback: FetchUserCallback,
      callback_args: {user_id: user_id}
    )
  end

  def update_user(user_id, attributes)
    request = @template.patch("/users/#{user_id}", json: attributes)
    Sidekiq::AsyncHttp.execute(
      request,
      callback: UpdateUserCallback,
      callback_args: {user_id: user_id}
    )
  end
end
```

### Callback Arguments

Pass custom data to your callbacks using the `callback_args` option:

```ruby
class FetchDataCallback
  def on_complete(response)
    # Access callback_args using symbol or string keys
    user_id = response.callback_args[:user_id]
    request_timestamp = response.callback_args[:request_timestamp]

    User.find(user_id).update!(
      external_data: response.json,
      fetched_at: request_timestamp
    )
  end

  def on_error(error)
    user_id = error.callback_args[:user_id]
    request_timestamp = error.callback_args[:request_timestamp]

    Rails.logger.error(
      "Failed to fetch data for user #{user_id} at #{request_timestamp}: #{error.message}"
    )
  end
end

# Pass data via callback_args option
Sidekiq::AsyncHttp.get(
  "https://api.example.com/users/#{user_id}",
  callback: FetchDataCallback,
  callback_args: {
    user_id: user_id,
    request_timestamp: Time.now.iso8601
  }
)
```

**Important details about callback_args:**

- Must be a Hash (or respond to `to_h`) containing only JSON-native types: `nil`, `true`, `false`, `String`, `Integer`, `Float`, `Array`, or `Hash`
- Hash keys will be converted to strings for serialization
- Nested hashes and hashes in arrays also have their keys converted to strings
- You can access callback_args using either symbol or string keys: `callback_args[:user_id]` or `callback_args["user_id"]`

### Sensitive Data Handling

Requests and responses from asynchronous HTTP requests will be pushed to Redis in order to call the completion job. This can raise security concerns if they contains sensitive data since the data will be stored in plain text.

You can configure an optional `encryptor` and `decryptor` to encrypt request and response data when it is serialized:

```ruby
Sidekiq::AsyncHttp.configure do |config|
  config.encryptor = ->(data) { MyEncryption.encrypt(data) }
  config.decryptor = ->(encrypted_value) { MyEncryption.decrypt(encrypted_value) }
end
```

The encryptor will be given a hash and should return a JSON safe value. The decryptor will be given the output from the encyptor and should return the original value.

If the [sidekiq-encrypted_args](https://github.com/bdurand/sidekiq-encrypted_args) gem is installed, it will be used automatically by default.

```ruby
# No additional configuration needed - encryption is automatic
Sidekiq::EncryptedArgs.configure!(secret: "YourSecretKey")
```

See the [documentation](https://github.com/bdurand/sidekiq-encrypted_args) for more details on configuring encryption with that gem.

## Configuration

The gem can be configured globally in an initializer:

```ruby
Sidekiq::AsyncHttp.configure do |config|
  # Maximum concurrent HTTP requests (default: 256)
  config.max_connections = 256

  # Default timeout for HTTP requests in seconds (default: 60)
  config.request_timeout = 60

  # Maximum number of host clients to pool (default: 100)
  config.connection_pool_size = 100

  # Connection timeout in seconds (default: nil, uses request_timeout)
  config.connection_timeout = 10

  # Number of retries for failed requests (default: 3)
  config.retries = 3

  # HTTP/HTTPS proxy URL (default: nil)
  # Supports authentication: "http://user:pass@proxy.example.com:8080"
  config.proxy_url = "http://proxy.example.com:8080"

  # Default User-Agent header for all requests (optional)
  config.user_agent = "MyApp/1.0"

  # Timeout for graceful shutdown in seconds (default: the Sidekiq
  # shutdown timeout minus 2 seconds). This should be less than Sidekiq's
  # shutdown timeout
  config.shutdown_timeout = 23

  # Maximum response body size in bytes (default: 1MB)
  # Responses larger than this will trigger ResponseTooLargeError
  config.max_response_size = 1024 * 1024

  # Heartbeat interval for crash recovery in seconds (default: 60)
  config.heartbeat_interval = 60

  # Orphan detection threshold in seconds (default: 300)
  # Requests older than this without a heartbeat will be re-enqueued
  config.orphan_threshold = 300

  # Maximum number of redirects to follow (default: 5, 0 disables)
  config.max_redirects = 5

  # Whether to raise HttpError for non-2xx responses by default (default: false)
  config.raise_error_responses = false

  # Sidekiq options for RequestWorker and CallbackWorker
  config.sidekiq_options = {queue: "async_http", retry: 5}

  # Custom logger (defaults to Sidekiq.logger)
  config.logger = Rails.logger
end
```

See the [Configuration](lib/sidekiq/async_http/configuration.rb) class for all available options.

### Tuning Tips

- `max_connections`: Adjust this based on your system's resources. Each connection uses memory and file descriptors. A tuned system with sufficient resources can handle thousands of concurrent connections.
- `request_timeout`: Set this based on the expected response times of the APIs you are calling. AI APIs might sometimes take minutes to respond as they generate content.
- `connection_pool_size`: Controls how many connections to different hosts are kept alive. Increase for applications calling many different API endpoints.
- `connection_timeout`: Set this if you need to fail fast on connection establishment. Useful for detecting network issues quickly.
- `retries`: Number of times to retry a failed request before calling the error callback.
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
