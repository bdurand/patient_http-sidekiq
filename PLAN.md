# Async HTTP Sidekiq Gem Design Plan

## Overview

This gem (`sidekiq-async-http`) provides a mechanism to offload long-running HTTP requests from Sidekiq workers to a dedicated async I/O processor running in the same process, freeing the worker thread immediately while the HTTP request is in flight.

---

## Architecture Design

### High-Level Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Sidekiq Process                                   │
│                                                                             │
│  ┌──────────────┐     ┌──────────────────────────────────────────────────┐ │
│  │   Worker     │     │         Async HTTP Processor (Thread)            │ │
│  │   Thread     │     │                                                  │ │
│  │              │     │  ┌─────────────────────────────────────────────┐ │ │
│  │  1. Build    │     │  │          Async Reactor (Fiber Pool)         │ │ │
│  │     Request  │────▶│  │                                             │ │ │
│  │              │     │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐       │ │ │
│  │  2. Enqueue  │     │  │  │ Request │ │ Request │ │ Request │ ...   │ │ │
│  │     & Return │     │  │  │ Fiber 1 │ │ Fiber 2 │ │ Fiber 3 │       │ │ │
│  │              │     │  │  └────┬────┘ └────┬────┘ └────┬────┘       │ │ │
│  └──────────────┘     │  │       │           │           │             │ │ │
│                       │  └───────┼───────────┼───────────┼─────────────┘ │ │
│                       │          ▼           ▼           ▼               │ │
│                       │  ┌─────────────────────────────────────────────┐ │ │
│                       │  │     Connection Pool (per-host keep-alive)   │ │ │
│                       │  │     HTTP/1.1, HTTP/2, TLS                   │ │ │
│                       │  └─────────────────────────────────────────────┘ │ │
│                       │                       │                          │ │
│                       │                       ▼                          │ │
│                       │              3. On completion:                   │ │
│                       │                 Enqueue success/error worker     │ │
│                       └──────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why This Architecture?

1. **In-process, separate thread**: The async processor runs in a dedicated thread within the Sidekiq process. This avoids IPC complexity while keeping HTTP I/O completely isolated from worker threads.

2. **Fiber-based concurrency with `async` gem**: Ruby 3.2+ has mature Fiber Scheduler support with improved memory efficiency (~2-4KB per fiber). The `async` gem leverages this to handle thousands of concurrent HTTP requests in a single thread without blocking.

3. **Thread-safe queue for communication**: Workers push requests to a `Thread::Queue`, the processor consumes them. This is simple, fast, and avoids complex synchronization.

---

## Core Library Choice: `async-http`

The **`async-http`** gem (part of the `socketry/async` ecosystem) is the best choice:

| Feature | async-http | Typhoeus | Net::HTTP |
|---------|------------|----------|-----------|
| Non-blocking I/O | ✅ Fiber-based | ✅ libcurl multi | ❌ Blocking |
| HTTP/2 Support | ✅ Native | ⚠️ Via libcurl | ❌ No |
| Connection Pooling | ✅ Built-in | ✅ Built-in | ❌ Manual |
| Keep-Alive | ✅ Automatic | ✅ Automatic | ⚠️ Manual |
| Ruby-native | ✅ Pure Ruby | ❌ C extension | ✅ Stdlib |
| Modern TLS | ✅ Via OpenSSL | ✅ Via libcurl | ✅ Via OpenSSL |

---

## Ruby 3.2+ Features

Targeting Ruby 3.2+ enables several improvements:

### 1. `Data.define` for Value Objects

Immutable value objects with less boilerplate:

```ruby
Request = Data.define(
  :id, :method, :url, :headers, :body, :timeout,
  :original_worker_class, :success_worker_class, :error_worker_class,
  :original_args, :enqueued_at, :metadata
) do
  def initialize(id: SecureRandom.uuid, method: :get, headers: {}, body: nil,
                 timeout: 30, enqueued_at: Time.now, metadata: {}, **rest)
    super(id:, method:, headers:, body:, timeout:, enqueued_at:, metadata:, **rest)
  end
end
```

**Benefits**: Immutability by default, built-in `#==`, `#hash`, `#to_h`, `#deconstruct_keys` for pattern matching.

### 2. Improved Fiber Efficiency

Ruby 3.2 has ~2-4KB memory per fiber (vs ~8KB+ in 3.0), directly impacting max concurrent requests.

### 3. `Fiber#storage` for Request Context

```ruby
Fiber[:current_request] = request
# Later in error handling:
request = Fiber[:current_request]
```

### 4. Pattern Matching for Error Classification

```ruby
case exception
in Async::TimeoutError then :timeout
in OpenSSL::SSL::SSLError then :ssl
in Errno::ECONNREFUSED | Errno::ECONNRESET then :connection
else :unknown
end
```

---

## Component Design

### 1. `Sidekiq::AsyncHttp::Request`

An immutable value object using `Data.define`:

```ruby
# Attributes:
# - id: UUID for tracking (auto-generated)
# - method: :get, :post, :put, :patch, :delete, :head, :options
# - url: Full URL string
# - headers: Hash of headers
# - body: String or nil
# - timeout: Float (seconds), default 30
# - original_worker_class: String (class name of initiating worker)
# - success_worker_class: String (class name for success callback)
# - error_worker_class: String (class name for error callback)
# - original_args: Array (original job arguments to pass through)
# - enqueued_at: Time (auto-generated)
# - metadata: Hash (arbitrary user data to pass through)
```

### 2. `Sidekiq::AsyncHttp::Response`

An immutable value object representing the HTTP response:

```ruby
# Attributes:
# - status: Integer (HTTP status code)
# - headers: Hash
# - body: String
# - duration: Float (seconds)
# - request_id: UUID (links back to request)
# - protocol: String ("HTTP/1.1", "HTTP/2", etc.)
#
# Methods:
# - #success? (status 200-299)
# - #redirect? (status 300-399)
# - #client_error? (status 400-499)
# - #server_error? (status 500-599)
```

### 3. `Sidekiq::AsyncHttp::Error`

A serializable error representation using `Data.define`:

```ruby
# Attributes:
# - class_name: String
# - message: String
# - backtrace: Array<String>
# - request_id: UUID
# - error_type: Symbol (:timeout, :connection, :ssl, :protocol, :unknown)
#
# Class methods:
# - .from_exception(exception, request_id:) - uses pattern matching for classification
```

### 4. `Sidekiq::AsyncHttp::Configuration`

Global configuration with sensible defaults:

```ruby
Configuration = Data.define(
  :max_connections,
  :idle_connection_timeout,
  :default_request_timeout,
  :shutdown_timeout,
  :logger,
  :enable_http2,
  :dns_cache_ttl,
  :backpressure_strategy
) do
  def initialize(
    max_connections: 256,
    idle_connection_timeout: 60,
    default_request_timeout: 30,
    shutdown_timeout: 25,
    logger: nil,
    enable_http2: true,
    dns_cache_ttl: 300,
    backpressure_strategy: :block
  )
    super
  end

  def validate!
    raise ArgumentError, "max_connections must be > 0" unless max_connections > 0
    raise ArgumentError, "backpressure_strategy invalid" unless
      %i[block raise drop_oldest].include?(backpressure_strategy)
    self
  end
end
```

**Backpressure Strategies** (when `max_connections` is reached):

| Strategy | Behavior |
|----------|----------|
| `:block` | Block the calling thread until a slot is available |
| `:raise` | Raise `Sidekiq::AsyncHttp::BackpressureError` immediately |
| `:drop_oldest` | Cancel oldest in-flight request, re-enqueue its original worker |

### 5. `Sidekiq::AsyncHttp::Metrics`

Thread-safe metrics collection using `Concurrent::AtomicFixnum` and `Concurrent::Map`:

```ruby
# Exposed metrics:
# - in_flight_count: Integer
# - in_flight_requests: Array<Request> (frozen snapshot)
# - total_requests: Integer
# - total_duration: Float (sum of all request durations)
# - average_duration: Float (computed: total_duration / total_requests)
# - error_count: Integer
# - errors_by_type: Hash<Symbol, Integer>
# - connections_per_host: Hash<String, Integer>
# - connection_wait_time: Float (moving average)
# - backpressure_events: Integer
# - queue_depth: Integer (requests waiting to be sent)
```

### 6. `Sidekiq::AsyncHttp::ConnectionPool`

Wrapper around `Async::HTTP::Client` management:

```ruby
# Responsibilities:
# - Create and cache Async::HTTP::Client instances per host
# - Respect max_connections
# - Track active connections per host
# - Close connections idle longer than idle_connection_timeout
# - Background fiber for periodic idle connection cleanup
#
# Methods:
# - #acquire(url) - returns client, blocks/raises if at limit
# - #release(url, client) - returns client to pool
# - #close_idle - close connections exceeding idle timeout
# - #stats - returns connection statistics
```

### 7. `Sidekiq::AsyncHttp::Processor`

The heart of the gem. Runs in a dedicated thread and manages the async reactor:

```ruby
# Responsibilities:
# - Starts an Async reactor in a background thread
# - Consumes requests from a Thread::Queue
# - Spawns a Fiber for each HTTP request
# - Manages connection pool via ConnectionPool
# - Implements backpressure strategies
# - Tracks in-flight requests
# - Collects metrics
# - Handles graceful shutdown
# - Re-enqueues in-flight requests on shutdown
#
# States: :stopped, :running, :draining, :stopping
```

### 8. `Sidekiq::AsyncHttp::Client`

The public API that Sidekiq workers use:

```ruby
# Main method:
# Sidekiq::AsyncHttp.request(
#   method: :post,
#   url: "https://api.example.com/webhooks",
#   headers: { "Content-Type" => "application/json" },
#   body: payload.to_json,
#   success_worker: "WebhookSuccessWorker",
#   error_worker: "WebhookErrorWorker",
#   original_args: [webhook_id, attempt],
#   timeout: 60
# )
#
# Convenience methods:
# - Sidekiq::AsyncHttp.get(url, **options)
# - Sidekiq::AsyncHttp.post(url, **options)
# - Sidekiq::AsyncHttp.put(url, **options)
# - Sidekiq::AsyncHttp.patch(url, **options)
# - Sidekiq::AsyncHttp.delete(url, **options)
```

### 9. `Sidekiq::AsyncHttp::Lifecycle`

Hooks into Sidekiq's lifecycle for startup and shutdown:

```ruby
# Sidekiq.configure_server do |config|
#   config.on(:startup) { Sidekiq::AsyncHttp.start }
#   config.on(:quiet) { Sidekiq::AsyncHttp.quiet }     # Stop accepting new requests
#   config.on(:shutdown) { Sidekiq::AsyncHttp.stop }   # Graceful shutdown
# end
```

**Shutdown behavior**:
1. On `:quiet` - Stop accepting new requests, mark processor as draining
2. On `:shutdown` - Wait up to `shutdown_timeout` seconds for in-flight requests
3. For any remaining in-flight requests, re-enqueue the original worker with original args

---

## Request/Response Flow Detail

### Happy Path

```
1. Worker creates a Sidekiq::AsyncHttp::Request to set headers, base URL, etc.
2. Worker calls async_request on the request to create an async request for a URL
3. Worker calls perform on the async request specifying the success and error worker callback classes
4. Request pushed to Thread::Queue
5. Worker returns immediately (Sidekiq job completes)
6. Processor's reactor loop picks up request
7. New Fiber spawned for this request
8. Fiber makes HTTP request via ConnectionPool → Async::HTTP::Client
9. Response received, Fiber builds Response object
10. Processor enqueues success_worker_class.perform_async(response.to_h, *original_args)
11. Metrics updated
12. Fiber completes
```

### Error Path

```
1-6. Same as happy path
7. HTTP request raises exception (timeout, connection refused, etc.)
8. Exception caught and classified via pattern matching
9. Error object built with .from_exception
10. Processor enqueues error_worker_class.perform_async(error.to_h, *original_args)
11. Metrics updated (error_count, errors_by_type)
12. Fiber completes
```

### Shutdown Path

```
1. SIGTERM received by Sidekiq
2. Sidekiq fires :quiet event → Sidekiq::AsyncHttp.quiet called
3. Processor stops accepting new requests (returns error for new requests)
4. Sidekiq fires :shutdown event → Sidekiq::AsyncHttp.stop called
5. Processor waits up to shutdown_timeout for in-flight requests
6. For any remaining in-flight requests:
   a. Cancel the HTTP request
   b. Enqueue original_worker_class.perform_async(*original_args)
7. Connection pool closed
8. Processor thread joins
9. Shutdown complete
```

---

## Connection Pooling Constraints & Practical Limits

### Resource Constraints

| Resource | Limit | How to Check/Modify |
|----------|-------|---------------------|
| File descriptors | Default: 1,024 | `ulimit -n` / systemd / `/etc/security/limits.conf` |
| Kernel TCP memory | System-dependent | `/proc/sys/net/ipv4/tcp_mem` |
| Ephemeral ports | ~28,000 | `/proc/sys/net/ipv4/ip_local_port_range` |
| Memory per connection | ~128-256KB (kernel buffers) | Not directly configurable |
| Memory per Fiber | ~2-4KB (Ruby 3.2+) | N/A |
| DNS resolution | Can bottleneck | Use connection reuse, local caching |

### Memory Calculation Example (10,000 concurrent connections)

```
Kernel TCP buffers:  10,000 × 200KB  = ~2GB
Ruby Fiber memory:   10,000 × 4KB   = ~40MB
SSL session cache:   10,000 × 2KB   = ~20MB (if HTTPS)
Application memory:  10,000 × 10KB  = ~100MB (request/response data)
─────────────────────────────────────────────
Total estimate:                       ~2.2GB
```

### HTTP/2 Multiplexing Benefit

```
Without HTTP/2: 1000 concurrent requests to same host = 1000 connections
With HTTP/2:    1000 concurrent requests to same host = ~10-50 connections
```

`async-http` supports HTTP/2 automatically when the server supports it.

### Recommended Configuration Tiers

**Small (default) - Development / Low traffic:**
```ruby
Sidekiq::AsyncHttp.configure do |config|
  config.max_connections = 64
  config.idle_connection_timeout = 60
end
# Requires: ulimit -n 1024 (default)
# Memory: ~100MB overhead
```

**Medium - Standard production:**
```ruby
Sidekiq::AsyncHttp.configure do |config|
  config.max_connections = 256
  config.idle_connection_timeout = 120
end
# Requires: ulimit -n 4096
# Memory: ~300MB overhead
```

**Large - High throughput:**
```ruby
Sidekiq::AsyncHttp.configure do |config|
  config.max_connections = 1024
  config.idle_connection_timeout = 300
end
# Requires: ulimit -n 16384
# Memory: ~2.5GB overhead
```

**Extra Large - Extreme throughput:**
```ruby
Sidekiq::AsyncHttp.configure do |config|
  config.max_connections = 4096
  config.idle_connection_timeout = 300
end
# Requires: ulimit -n 65536, kernel tuning
# Memory: ~12GB overhead
```

### Practical Limits Summary

| Deployment | Safe Concurrent Requests |
|------------|-------------------------|
| Default Linux (1024 FDs) | ~500 |
| Tuned Linux (16K FDs) | ~10,000 |
| Heavily tuned + dedicated | ~50,000+ |

For most production use cases, **1,000-5,000 concurrent requests** is a reasonable target without special system tuning beyond raising file descriptor limits.

---

## Directory Structure

```
sidekiq-async-http/
├── lib/
│   ├── sidekiq-async_http.rb
│   └── sidekiq-async_http/
│       ├── configuration.rb
│       ├── async_request.rb
│       ├── request.rb
|       ├── http_headers.rb
│       ├── response.rb
│       ├── error.rb
│       ├── processor.rb
│       ├── connection_pool.rb
│       ├── metrics.rb
│       ├── lifecycle.rb
│       └── client.rb
├── spec/
│   ├── spec_helper.rb
│   ├── sidekiq-async_http/
│   │   ├── request_spec.rb
│   │   ├── response_spec.rb
│   │   ├── error_spec.rb
│   │   ├── processor_spec.rb
│   │   ├── connection_pool_spec.rb
│   │   ├── metrics_spec.rb
│   │   ├── lifecycle_spec.rb
│   │   ├── client_spec.rb
│   │   └── configuration_spec.rb
│   └── integration/
│       ├── full_workflow_spec.rb
│       └── shutdown_spec.rb
├── .standard.yml
├── Gemfile
├── sidekiq-async-http.gemspec
├── README.md
├── CHANGELOG.md
└── LICENSE
```

---

## Dependencies

```ruby
# sidekiq-async-http.gemspec
Gem::Specification.new do |spec|
  spec.name = "sidekiq-async-http"
  spec.required_ruby_version = ">= 3.2.0"

  spec.add_dependency "sidekiq", ">= 7.0"
  spec.add_dependency "async", "~> 2.0"
  spec.add_dependency "async-http", "~> 0.60"
  spec.add_dependency "concurrent-ruby", "~> 1.2"

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "webmock", "~> 3.18"
  spec.add_development_dependency "async-rspec", "~> 1.17"
  spec.add_development_dependency "timecop", "~> 0.9"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "standard", "~> 1.30"
end
```

```yaml
# .standard.yml
ruby_version: 3.2
ignore:
  - "spec/**/*":
      - Lint/ConstantDefinitionInBlock
```

---

## Testing Strategy

### WebMock Compatibility

WebMock's default stubbing doesn't work out-of-box with `async-http`. Solutions:

1. Create test helpers that spawn real local HTTP servers using `Async::HTTP::Server`
2. Use dependency injection to mock at the Client level for unit tests
3. Use `async-rspec` helpers for async-aware test execution

### Test Categories

1. **Unit tests**: Test each class in isolation with mocked dependencies
2. **Integration tests**: Test full request → response → callback flow
3. **Shutdown tests**: Test graceful shutdown and re-enqueue behavior
4. **Metrics tests**: Verify metrics accuracy under concurrent load
5. **Backpressure tests**: Verify each backpressure strategy works correctly

---

## TODO List for Implementation

### Phase 1: Project Setup

```
[x] 1.1 Create gem skeleton with bundler (`bundle gem sidekiq-async-http`)

[x] 1.2 Configure gemspec with metadata and dependencies:
        - Set required_ruby_version >= 3.2.0
        - Add runtime dependencies: sidekiq >= 7.0, async ~> 2.0,
          async-http ~> 0.60, concurrent-ruby ~> 1.2

[x] 1.3 Set up RSpec with spec_helper.rb including:
        - SimpleCov for coverage (start before requiring lib)
        - WebMock configuration (disable_net_connect!)
        - Async::RSpec helpers (include Async::RSpec::Reactor)
        - Sidekiq::Testing.fake! mode
        - Helper to reset Sidekiq::AsyncHttp between tests

[x] 1.4 Create .standard.yml:
        - Set ruby_version: 3.2

[x] 1.5 Create Rakefile with default task running standardrb and rspec

[x] 1.6 Create lib/sidekiq-async_http.rb with:
        - Module skeleton
        - Autoloads for all components
        - Module-level accessors for configuration, processor, metrics
        - Public API method stubs

[x] 1.7 Verify `bundle exec rake` runs successfully (standardrb + empty specs)
```

### Phase 2: Value Objects

```
[x] 2.0 Define builder pattern object for building an HTTP request.
        - Define builder object with attributes: http_method, url, headers, params, body, timeout, open_timeout, read_timeout, write_timeout
        - Calling any of the attribute methods on the builder object creates a new builder object with that attribute set to the specified value and returns it.
        - Calling `header` or `param` will merge the value with the existing hash. Calling `headers` or `params` will replace the entire hash.
        - Calling `request` will return a Data object with all attributes set.
        - Write specs for each attribute method and the final `request` method.
[x] 2.1 Implement Request:
        - Define with: id, request, original_worker_class, success_worker_class,
          error_worker_class, original_args, enqueued_at, metadata
        - Override initialize for defaults:
          - id: SecureRandom.uuid
          - enqueued_at: Time.now
          - metadata: {}
        - Add #validate! method that raises ArgumentError for:
          - Missing url
          - Missing success_worker_class
          - Missing error_worker_class
          - Invalid method (not in VALID_METHODS constant)
        - Implement #to_h with string keys for JSON serialization
        - Implement .from_h class method for deserialization
        - Write specs for:
          - Default value generation
          - Custom value assignment
          - Validation errors
          - Serialization round-trip

[x] 2.2 Implement Response:
        - Define with: status, headers, body, duration, request_id, protocol, url, method
        - Initialize takes an Async::HTTP::Response, duration, and request_id
        - Headers is an instance of Sidekiq::AsyncHttp::HttpHeaders
        - Implement predicate methods:
          - #success? (status 200-299)
          - #redirect? (status 300-399)
          - #client_error? (status 400-499)
          - #server_error? (status 500-599)
          - #error? (400-599)
        - Implement #to_h with string keys
        - Implement .from_h class method to reconstruct from hash
        - Implement #json to return parsed JSON body if Content-Type is application/json or raise an error otherwise
        - Write specs for all predicates and serialization

[x] 2.3 Implement Error:
        - Define with: class_name, message, backtrace, request_id, error_type
        - Define ERROR_TYPES = %i[timeout connection ssl protocol unknown].freeze
        - Implement .from_exception(exception, request_id:) using pattern matching:
          - Async::TimeoutError → :timeout
          - OpenSSL::SSL::SSLError → :ssl
          - Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH → :connection
          - Async::HTTP::Protocol::Error → :protocol
          - else → :unknown
        - Implement #to_h with string keys
        - Implement .from_h class method
        - Implement #error_class that returns the actual Exception class constant from the class_name
        - Write specs for each exception type classification
```

### Phase 3: Configuration

```
[x] 3.1 Implement Configuration using Data.define:
        - Define with all attributes:
          - max_connections (default: 256)
          - idle_connection_timeout (default: 60)
          - default_request_timeout (default: 30)
          - shutdown_timeout (default: 25)
          - logger (default: nil, will use Sidekiq.logger)
          - enable_http2 (default: true)
          - dns_cache_ttl (default: 300)
          - backpressure_strategy (default: :raise)
        - Implement #validate! that raises ArgumentError for:
          - Non-positive numeric values
          - Invalid backpressure_strategy (must be :block, :raise, or :drop_oldest)
        - Implement #to_h for inspection
        - Implement #logger that returns configured logger or Sidekiq.logger
        - Write specs for defaults, custom values, and validation errors

[x] 3.2 Add configuration DSL to main module:
        - Sidekiq::AsyncHttp.configure { |config| ... } - yields Config::Builder
        - Implement Config::Builder class that collects settings and builds
          immutable Configuration
        - Sidekiq::AsyncHttp.configuration - returns current frozen config
        - Sidekiq::AsyncHttp.reset_configuration! - resets to defaults (for testing)
        - Write specs for DSL usage and reset behavior
```

### Phase 4: Metrics

```
[x] 4.1 Implement Metrics class:
        - Use Concurrent::AtomicFixnum for:
          - @total_requests
          - @error_count
          - @backpressure_events
        - Use Concurrent::AtomicReference for:
          - @total_duration (Float)
        - Use Concurrent::Map for:
          - @in_flight_requests (request_id → Request)
          - @errors_by_type (Symbol → AtomicFixnum)
          - @connections_per_host (host → AtomicFixnum)
        - Implement #record_request_start(request):
          - Add to @in_flight_requests
        - Implement #record_request_complete(request, duration):
          - Remove from @in_flight_requests
          - Increment @total_requests
          - Add duration to @total_duration
        - Implement #record_error(request, error_type):
          - Increment @error_count
          - Increment @errors_by_type[error_type]
        - Implement #record_backpressure:
          - Increment @backpressure_events
        - Implement #update_connections(host, delta):
          - Update @connections_per_host[host]
        - Implement reader methods:
          - #in_flight_count → Integer
          - #in_flight_requests → Array<Request> (frozen copy)
          - #total_requests → Integer
          - #average_duration → Float (total_duration / total_requests, or 0)
          - #error_count → Integer
          - #errors_by_type → Hash<Symbol, Integer> (frozen copy)
          - #connections_per_host → Hash<String, Integer> (frozen copy)
          - #backpressure_events → Integer
        - Implement #to_h (snapshot of all metrics)
        - Implement #reset! (for testing)
        - Write specs including thread-safety tests with multiple threads
```

### Phase 5: Connection Pool

```
[x] 5.1 Implement ConnectionPool class:
        - Initialize with configuration
        - Use Concurrent::Map for @clients (host → Async::HTTP::Client)
        - Use Concurrent::Map for @connection_counts (host → AtomicFixnum)
        - Use Concurrent::AtomicFixnum for @total_connections
        - Implement #client_for(uri):
          - Parse URI to extract host
          - Return existing client if cached
          - Check limits (per-host and total)
          - If at limit, handle according to backpressure_strategy
          - Create new Async::HTTP::Client with:
            - HTTP/2 support based on config.enable_http2
          - Cache and return client
        - Implement #with_client(uri, &block):
          - Acquire client
          - Yield to block
          - Handle errors
          - Return client to pool
        - Implement #close_idle_connections:
          - Close clients that have been idle > idle_connection_timeout
        - Implement #close_all:
          - Close all clients for shutdown
        - Implement #stats → Hash with connection counts
        - Write specs:
          - Client creation and caching
          - Per-host limit enforcement
          - Total limit enforcement
          - Each backpressure strategy
          - Idle connection cleanup

[x] 5.2 Implement backpressure handling in ConnectionPool:
        - For :block strategy:
          - Use Async::Condition to wait for available slot
          - Wake waiters when connection is released
        - For :raise strategy:
          - Raise Sidekiq::AsyncHttp::BackpressureError immediately
        - For :drop_oldest strategy:
          - Coordinate with Processor to cancel oldest request
          - This requires callback/event mechanism
        - Define BackpressureError < StandardError
        - Write specs for each strategy under load
```

### Phase 6: Processor (Core)

```
[x] 6.1 Implement Processor class - basic structure:
        - Initialize with:
          - @queue = Thread::Queue.new
          - @metrics = Metrics.new
          - @config = Sidekiq::AsyncHttp.configuration
          - @connection_pool = ConnectionPool.new(@config)
          - @state = Concurrent::AtomicReference.new(:stopped)
          - @reactor_thread = nil
          - @shutdown_barrier = Concurrent::Event.new
        - Define STATES = %i[stopped running draining stopping].freeze
        - Implement #start:
          - Return if already running
          - Set state to :running
          - Spawn @reactor_thread that runs the async reactor
        - Implement #stop(timeout: nil):
          - Set state to :stopping
          - Wait for in-flight requests up to timeout
          - Re-enqueue remaining requests' original workers
          - Close connection pool
          - Join reactor thread
          - Set state to :stopped
        - Implement #drain:
          - Set state to :draining
          - Stop accepting new requests
        - Implement state predicates: #running?, #stopped?, #draining?, #stopping?
        - Implement #enqueue(request):
          - Raise if not running or draining
          - Push to @queue
        - Write specs for state transitions

[x] 6.2 Implement Processor - reactor loop:
        - In reactor thread, run Async do |task| ... end
        - Create consumer fiber that loops:
          - Pop request from @queue (with timeout to check for shutdown)
          - Check state, break if stopping
          - Check max_connections limit
          - If at limit, handle backpressure
          - Spawn new fiber for request via task.async
        - Handle InterruptedError for clean shutdown
        - Write specs verifying:
          - Requests are consumed from queue
          - Fibers are spawned
          - Backpressure is applied at limit

[x] 6.3 Implement Processor - HTTP execution fiber:
        - Set Fiber[:current_request] = request
        - Record request start in metrics
        - Start timer for duration tracking
        - Use @connection_pool.with_client(request.url) do |client|
          - Build Async::HTTP::Request from our Request object
          - Set timeout using Async::Task.with_timeout
          - Execute request: response = client.call(http_request)
          - Read response body: body = response.read
          - Build Response object from Async::HTTP::Response
        - Calculate duration
        - Record request complete in metrics
        - Call #handle_success(request, response)
        - Write specs with mocked HTTP client

[x] 6.4 Implement Processor - success callback:
        - Implement #handle_success(request, response):
          - Get worker class from class name taking into account module namespaces
          - Enqueue job: worker_class.perform_async(response.to_h, *request.original_args)
          - Log success at debug level
        - Handle errors during enqueue (log and continue)
        - Write specs verifying:
          - Correct worker class is resolved
          - Job is enqueued with correct arguments
          - Response is properly serialized

[x] 6.5 Implement Processor - error handling:
        - Wrap HTTP execution in rescue block
        - Implement #handle_error(request, exception):
          - Build Error using Error.from_exception(exception, request_id: request.id)
          - Record error in metrics
          - Get worker class from class name taking into account module namespaces
          - Enqueue job: worker_class.perform_async(error.to_h, *request.original_args)
          - Log error at warn level
        - Write specs for:
          - Timeout errors
          - Connection refused
          - SSL errors
          - Protocol errors
          - Unknown errors

[x] 6.6 Implement Processor - graceful shutdown:
        - In #stop:
          - Set state to :stopping
          - Signal reactor to stop accepting new requests
          - Calculate deadline from timeout
          - Loop until in_flight_count == 0 or deadline passed:
            - Sleep briefly
            - Check in_flight_count
          - For remaining in-flight requests:
            - Cancel fiber if possible
            - Build list of requests to re-enqueue
          - For each request to re-enqueue:
            - Get worker class: Object.const_get(request.original_worker_class)
            - Enqueue: worker_class.perform_async(*request.original_args)
            - Log re-enqueue at info level
          - Close connection pool
          - Join reactor thread
        - Write specs for:
          - Clean shutdown (all requests complete)
          - Timeout shutdown (requests re-enqueued)
          - Multiple in-flight requests during shutdown
```

### Phase 7: Client (Public API)

```
[ ] 7.1 Implement Request validation and Sidekiq job handling:
        - Update Request#perform to validate parameters:
          - sidekiq_job: required hash with "class" and "args" keys minimum
          - If sidekiq_job not provided, use Sidekiq::Context.current (Sidekiq 8+)
          - success_worker: required string, worker class name for success callback
          - error_worker: optional string, worker class name for error callback
          - If no error_worker provided, log error and retry original job
        - Add Request#validate! method:
          - Validate request has method (symbol)
          - Validate request has url (String or URI object)
          - Raise ArgumentError with descriptive message if invalid
        - Add validation to Client#async_request:
          - Ensure method is a symbol
          - Ensure uri is provided (String or URI)
        - Write specs for:
          - Valid request with all parameters
          - Request validation (missing/invalid method, url)
          - Perform validation (missing/invalid sidekiq_job, success_worker)
          - Using Sidekiq::Context.current when sidekiq_job not provided
          - Error worker optional (falls back to retry behavior)

[ ] 7.2 Implement Request processing integration:
        - Update Request#perform to enqueue to processor:
          - Build internal request object from Client state and perform params
          - Call Sidekiq::AsyncHttp.processor.enqueue(self)
          - Return request.id
        - Raise Sidekiq::AsyncHttp::NotRunningError if processor not running
        - Write specs for:
          - Successful enqueue to processor
          - NotRunningError when processor not started
          - Request ID returned

[ ] 7.3 Update Client convenience methods (already implemented):
        - async_get(uri, **options) → async_request(:get, uri, **options)
        - async_post(uri, **options) → async_request(:post, uri, **options)
        - async_put(uri, **options) → async_request(:put, uri, **options)
        - async_patch(uri, **options) → async_request(:patch, uri, **options)
        - async_delete(uri, **options) → async_request(:delete, uri, **options)
        - Verify specs exist and pass

[ ] 7.4 Add Sidekiq::AsyncHttp module accessor methods:
        - .metrics → returns processor.metrics
        - .processor → returns @processor (internal)
        - .running? → processor&.running? || false
        - Write specs
```

### Phase 8: Lifecycle Integration

```
[ ] 8.1 Implement Lifecycle module:
        - Sidekiq::AsyncHttp.start:
          - Return if already running
          - Create new Processor
          - Call processor.start
          - Log startup at info level
        - Sidekiq::AsyncHttp.quiet:
          - Return unless running
          - Call processor.drain
          - Log quiet at info level
        - Sidekiq::AsyncHttp.stop:
          - Return unless running
          - Call processor.stop(timeout: configuration.shutdown_timeout)
          - Set @processor = nil
          - Log shutdown at info level
        - Write specs for full lifecycle

[ ] 8.2 Create Sidekiq server middleware/hooks:
        - Create lib/sidekiq-async_http/sidekiq.rb:
          - Sidekiq.configure_server do |config|
              config.on(:startup) { Sidekiq::AsyncHttp.start }
              config.on(:quiet) { Sidekiq::AsyncHttp.quiet }
              config.on(:shutdown) { Sidekiq::AsyncHttp.stop }
            end
        - User just needs to require "sidekiq-async_http/sidekiq" in initializer
        - Document in README
        - Write integration specs verifying hooks are registered
```

### Phase 9: Integration Tests

```
[ ] 9.1 Create test support helpers:
        - Create spec/support/test_workers.rb:
          - TestSuccessWorker (records calls to class variable)
          - TestErrorWorker (records calls to class variable)
          - TestOriginalWorker (records calls to class variable)
        - Create spec/support/test_server.rb:
          - Helper to start Async::HTTP::Server for integration tests
          - Configurable response status, headers, body, delay
        - Create spec/support/async_helpers.rb:
          - Helper to run async code in tests
          - Helper to wait for condition with timeout

[ ] 9.2 Write full workflow integration test:
        - Start test HTTP server returning 200 OK
        - Start processor
        - Make async POST request with test workers
        - Wait for request to complete
        - Verify TestSuccessWorker.perform_async was called
        - Verify response hash contains correct status, body
        - Verify original_args passed through correctly
        - Stop processor
        - Stop test server

[ ] 9.3 Write error handling integration tests:
        - Test timeout error:
          - Start server with long delay
          - Make request with short timeout
          - Verify TestErrorWorker called with error_type: "timeout"
        - Test connection refused:
          - Make request to non-listening port
          - Verify TestErrorWorker called with error_type: "connection"
        - Test SSL error:
          - Make HTTPS request to HTTP-only server (or invalid cert)
          - Verify TestErrorWorker called with error_type: "ssl"

[ ] 9.4 Write shutdown integration tests:
        - Test clean shutdown:
          - Start request with short duration
          - Call stop with long timeout
          - Verify success worker called (request completed)
        - Test forced shutdown:
          - Start request with long delay
          - Call stop with short timeout
          - Verify TestOriginalWorker.perform_async called (re-enqueued)
          - Verify original args passed correctly
        - Test multiple in-flight:
          - Start 5 requests with varying delays
          - Call stop with medium timeout
          - Verify completed requests got success callback
          - Verify incomplete requests got re-enqueued

[ ] 9.5 Write metrics integration test:
        - Start processor
        - Make 10 successful requests
        - Make 2 failing requests (timeout)
        - Verify metrics:
          - total_requests == 12
          - error_count == 2
          - errors_by_type[:timeout] == 2
          - average_duration > 0
          - in_flight_count == 0 (after completion)

[ ] 9.6 Write backpressure integration tests:
        - Test :block strategy:
          - Set max_connections = 2
          - Start 5 requests with slow server
          - Verify only 2 fibers running initially
          - Verify all 5 eventually complete
        - Test :raise strategy:
          - Set max_connections = 2
          - Set backpressure_strategy = :raise
          - Start 5 requests quickly
          - Verify BackpressureError raised for requests 3-5
        - Test :drop_oldest strategy:
          - Set max_connections = 2
          - Set backpressure_strategy = :drop_oldest
          - Start 5 requests
          - Verify oldest requests get re-enqueued
          - Verify newest requests complete
```

### Phase 10: Documentation & Polish

```
[ ] 10.1 Write comprehensive README.md:
         - Badges (CI status, gem version, coverage)
         - Overview and motivation
         - Installation instructions
         - Quick start guide with minimal example
         - Configuration reference (all options with descriptions)
         - Worker examples:
           - Basic success worker
           - Error worker with retry logic
           - Original worker for re-enqueue handling
         - Metrics access and monitoring
         - Shutdown behavior explanation
         - Connection pooling and tuning guide
         - System requirements (file descriptors, etc.)
         - Troubleshooting section
         - Contributing guidelines
         - License

[ ] 10.2 Add YARD documentation:
         - Document all public classes and methods
         - Add @example tags for common usage
         - Add @param and @return tags
         - Add @raise tags for exceptions
         - Generate docs and verify formatting

[ ] 10.3 Create CHANGELOG.md:
         - Follow Keep a Changelog format
         - Document initial release features

[ ] 10.4 Add GitHub Actions CI workflow (.github/workflows/ci.yml):
         - Matrix: Ruby 3.2, 3.3, 3.4
         - Steps:
           - Checkout
           - Setup Ruby with bundler cache
           - Run `bundle exec standardrb`
           - Run `bundle exec rspec`
           - Upload coverage to CodeCov (on success)
         - Run on push and pull_request

[ ] 10.5 Add additional project files:
         - LICENSE (MIT)
         - .gitignore (appropriate for Ruby gems)
         - .rspec (--require spec_helper, --format documentation)
         - CONTRIBUTING.md

[ ] 10.6 Final review checklist:
         - All specs pass: `bundle exec rspec`
         - No linting errors: `bundle exec standardrb`
         - Code coverage > 90%
         - No security issues: `bundle audit`
         - Gem builds successfully: `gem build sidekiq-async-http.gemspec`
         - Gem installs successfully in fresh environment
         - Example code from README works
```

---

## Example Usage

### Configuration (config/initializers/sidekiq-async_http.rb)

```ruby
require "sidekiq-async_http/sidekiq"

Sidekiq::AsyncHttp.configure do |config|
  config.max_connections = 256
  config.default_request_timeout = 60
  config.shutdown_timeout = 25
  config.backpressure_strategy = :block
end
```

### Original Worker

```ruby
class WebhookDeliveryWorker
  include Sidekiq::Job

  def perform(webhook_id, payload)
    webhook = Webhook.find(webhook_id)

    Sidekiq::AsyncHttp.post(
      webhook.url,
      headers: {
        "Content-Type" => "application/json",
        "X-Webhook-Signature" => sign(payload)
      },
      body: payload.to_json,
      timeout: 30,
      success_worker: "WebhookSuccessWorker",
      error_worker: "WebhookErrorWorker",
      original_worker: self.class.name,
      original_args: [webhook_id, payload],
      metadata: { attempt: 1 }
    )

    # Worker returns immediately - doesn't wait for HTTP response
  end

  private

  def sign(payload)
    OpenSSL::HMAC.hexdigest("SHA256", ENV["WEBHOOK_SECRET"], payload)
  end
end
```

### Success Callback Worker

```ruby
class WebhookSuccessWorker
  include Sidekiq::Job

  def perform(response, webhook_id, payload)
    response = Sidekiq::AsyncHttp::Response.from_h(response)
    webhook = Webhook.find(webhook_id)

    if response.success?
      webhook.update!(last_delivered_at: Time.current, status: "delivered")
    else
      webhook.update!(
        status: "failed",
        last_error: "HTTP #{response.status}: #{response.body.truncate(500)}"
      )
    end
  end
end
```

### Error Callback Worker

```ruby
class WebhookErrorWorker
  include Sidekiq::Job

  def perform(error, webhook_id, payload)
    error = Sidekiq::AsyncHttp::Error.from_h(error)
    webhook = Webhook.find(webhook_id)

    webhook.update!(
      status: "error",
      last_error: "#{error.class_name}: #{error.message}"
    )

    # Retry with exponential backoff for transient errors
    if %w[timeout connection].include?(error.error_type)
      WebhookDeliveryWorker.perform_in(5.minutes, webhook_id, payload)
    end
  end
end
```

### Accessing Metrics

```ruby
# In a monitoring endpoint or admin panel
metrics = Sidekiq::AsyncHttp.metrics.to_h
# => {
#   in_flight_count: 42,
#   total_requests: 15_234,
#   average_duration: 0.234,
#   error_count: 127,
#   errors_by_type: { timeout: 98, connection: 29 },
#   connections_per_host: { "api.example.com" => 8, "webhooks.io" => 4 },
#   backpressure_events: 3
# }
```

---

## Quality check

- [ ] Code follows Ruby style guide (standardrb)
- [ ] Comprehensive RSpec test coverage
- [ ] Documentation complete and clear
- [ ] Examples tested and verified
- [ ] Threading code is as efficient as possible
- [ ] Tests don't contain unnecessary sleeps
- [ ] Tests don't contain unnecessary doubles/mocks
- [ ] Graceful shutdown works correctly

## Future Enhancements

1. **Request prioritization** - Priority queue for urgent requests
2. **Circuit breaker** - Per-host circuit breakers for failing endpoints
3. **Retry with backoff** - Built-in retry logic for transient failures
4. **Request deduplication** - Prevent duplicate in-flight requests
5. **Prometheus metrics exporter** - Export metrics in Prometheus format
6. **Web UI** - Sidekiq Web extension showing async HTTP stats
7. **Worker DSL Module** - Includable module providing:
   - Class-level `async_http_callbacks` for default success/error workers
   - Instance methods `async_get`, `async_post`, etc.
   - Automatic capture of job arguments for callbacks
   - Per-request callback override capability

   ```ruby
   class WebhookDeliveryWorker
     include Sidekiq::Job
     include Sidekiq::AsyncHttp::Worker

     async_http_callbacks(
       success: "WebhookSuccessWorker",
       error: "WebhookErrorWorker"
     )

     def perform(webhook_id, payload)
       webhook = Webhook.find(webhook_id)

       async_post(
         webhook.url,
         headers: { "Content-Type" => "application/json" },
         body: payload.to_json,
         callback_args: [webhook_id, payload]
       )
     end
   end
   ```