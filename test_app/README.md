# Test Application

This directory contains a simple test application for manually testing the Sidekiq::AsyncHttp gem.

## Prerequisites

Start Valkey (Redis) using docker-compose:

```bash
docker-compose up -d
```

## Features

- Embedded Sidekiq server with async HTTP processor
- High-performance Async HTTP server (async I/O, handles hundreds of concurrent requests)
- Sidekiq Web UI for monitoring
- Valkey (Redis) from docker-compose for job queue
- Example workers demonstrating different use cases
- Configurable via PORT environment variable

## Quick Start

### Option 1: Run Sidekiq server with Async HTTP (Recommended)

```bash
rake test_app
# or with custom port:
PORT=3000 rake test_app
```

This starts both a Sidekiq server with the AsyncHttp processor and a high-performance Async HTTP server serving the Sidekiq Web UI. The server uses async I/O and can handle hundreds of concurrent requests efficiently.

### Option 2: Run directly

```bash
ruby test_app/run.rb
# or if executable:
./test_app/run.rb
# with custom port:
PORT=3000 ruby test_app/run.rb
```

### Option 3: Run Web UI separately with Rack

```bash
rackup test_app/config.ru -p 9292
```

Then visit http://localhost:9292 to access the Sidekiq Web UI (without the Sidekiq server running).

### Option 4: Interactive console

```bash
rake console
# or:
ruby test_app/console.rb
```

Opens an IRB console with workers loaded for testing job enqueueing.

## Example Usage

Once the server is running, you can enqueue jobs from an IRB console:

```ruby
require "bundler/setup"
require "sidekiq"
require_relative "lib/sidekiq-async_http"
require_relative "test_app/workers"

# Configure Sidekiq
Sidekiq.configure_client do |config|
  config.redis = {url: "redis://localhost:6379/0"}
end

# Enqueue some test jobs
AsynchronousWorker.perform_async("https://httpbin.org/get")
AsynchronousWorker.perform_async("https://httpbin.org/delay/2", "GET")
PostWorker.perform_async("https://httpbin.org/post", {test: "data"})
TimeoutWorker.perform_async("https://httpbin.org/delay/10", 5)
```

## Test Workers

### AsynchronousWorker
Basic worker that makes HTTP requests and logs the response.

```ruby
AsynchronousWorker.perform_async("https://example.com", "GET")
```

### PostWorker
Demonstrates POST requests with JSON payload.

```ruby
PostWorker.perform_async("https://httpbin.org/post", {key: "value"})
```

### TimeoutWorker
Demonstrates custom timeout handling.

```ruby
TimeoutWorker.perform_async("https://httpbin.org/delay/10", 5)
```
