# Architecture

## Overview

Sidekiq::AsyncHttp provides a mechanism to offload long-running HTTP requests from Sidekiq worker threads to a dedicated async I/O processor. The gem uses Ruby's Fiber-based concurrency to handle hundreds of concurrent HTTP requests without blocking worker threads.

## Key Design Principles

1. **Non-blocking Workers**: Worker threads enqueue HTTP requests and immediately return, freeing them to process other jobs
2. **Singleton Processor**: One async I/O processor per Sidekiq process handles all HTTP requests using Fiber-based concurrency
3. **Callback Pattern**: HTTP responses are processed via callback workers that run as Sidekiq jobs
4. **Lifecycle Integration**: Processor lifecycle is tightly coupled with Sidekiq's startup and shutdown

## Core Components

### Processor
The heart of the system - a singleton that runs in a dedicated thread with its own Fiber reactor. Manages the async HTTP request queue and handles concurrent request execution using the `async` gem.

### Job Mixin
A module that workers include to gain async HTTP capabilities. Provides `async_get`, `async_post`, etc. methods and callback definitions (`on_completion`, `on_error`).

### Client
Request builder that constructs HTTP requests with proper URL joining, header merging, and parameter encoding.

### Request/Response
Immutable value objects representing HTTP requests and responses. Responses are serializable so they can be passed to callback workers.

### Inflight Registry
Tracks all in-flight HTTP requests for monitoring, crash recovery, and graceful shutdown.

### Metrics
Collects runtime statistics about request throughput, latency, errors, and processor state.

## Request Lifecycle

```mermaid
sequenceDiagram
    participant Worker as Worker Thread
    participant Job as Job Mixin
    participant Client as HTTP Client
    participant Processor as Async Processor
    participant Sidekiq as Sidekiq Queue
    participant Callback as Callback Worker

    Worker->>Job: perform(args)
    Job->>Client: async_get(url)
    Client->>Client: Build Request
    Client->>Processor: enqueue(request)
    activate Processor
    Note over Processor: Request stored<br/>in queue
    Processor-->>Job: Returns immediately
    Job-->>Worker: Job completes
    deactivate Processor

    Note over Worker: Worker thread free<br/>to process other jobs

    activate Processor
    Processor->>Processor: Fiber reactor<br/>dequeues request
    Processor->>Processor: Execute HTTP request<br/>(non-blocking)

    alt HTTP Request Completes
        Processor->>Sidekiq: Enqueue success callback
        Sidekiq->>Callback: Execute on_completion
        Callback->>Callback: Process response
    else Error Raised
        Processor->>Sidekiq: Enqueue error callback
        Sidekiq->>Callback: Execute on_error
        Callback->>Callback: Handle error
    end
    deactivate Processor
```

## Component Relationships

```mermaid
erDiagram
    PROCESSOR ||--o{ REQUEST : "manages queue of"
    PROCESSOR ||--|| INFLIGHT-REGISTRY : "tracks via"
    PROCESSOR ||--|| METRICS : "maintains"
    PROCESSOR ||--|| CONFIGURATION : "configured by"

    JOB-MIXIN ||--|| CLIENT : "uses"
    JOB-MIXIN ||--o{ CALLBACK-WORKER : "defines"

    CLIENT ||--|| REQUEST : "builds"
    REQUEST ||--|| RESPONSE : "yields"

    INFLIGHT-REGISTRY ||--o{ REQUEST : "tracks"
    CALLBACK-WORKER }o--|| RESPONSE : "receives"

    SIDEKIQ-WORKER ||--|| JOB-MIXIN : "includes"

    PROCESSOR {
        string state
        int queue_size
        thread reactor_thread
    }

    REQUEST {
        string http_method
        string url
        hash headers
        string body
        float timeout
    }

    RESPONSE {
        int status
        hash headers
        string body
        string http_method
        string url
    }

    JOB-MIXIN {
        class completion_worker
        class error_worker
    }

    INFLIGHT-REGISTRY {
        hash requests
        int capacity
    }

    METRICS {
        int requests_processed
        int errors_count
        float avg_latency
    }
```

## Process Model

Each Sidekiq process runs:
- Multiple worker threads (configured via Sidekiq concurrency)
- **One** async HTTP processor thread
- **One** fiber reactor within the processor thread

```
┌─────────────────────────────────────────────────────────────┐
│                    Sidekiq Process                          │
│                                                             │
│  ┌──────────────┐   ┌──────────────┐  ┌──────────────┐      │
│  │ Worker       │   │ Worker       │  │ Worker       │      │
│  │ Thread 1     │   │ Thread 2     │  │ Thread N     │      │
│  └──────┬───────┘   └──────┬───────┘  └──────┬───────┘      │
│         │                  │                 │              │
│         └──────────────────┼─────────────────┘              │
│                            │                                │
│                            ▼                                │
│               ┌─────────────────────────┐                   │
│               │  Async HTTP Processor   │                   │
│               │  (Dedicated Thread)     │                   │
│               │                         │                   │
│               │  ┌───────────────────┐  │                   │
│               │  │  Fiber Reactor    │  │                   │
│               │  │  ═════════════    │  │                   │
│               │  │  100+ concurrent  │  │                   │
│               │  │  HTTP requests    │  │                   │
│               │  └───────────────────┘  │                   │
│               └─────────────────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

## Concurrency Model

The processor uses Ruby's Fiber scheduler (`async` gem) for non-blocking I/O:

1. **Worker threads** remain free while HTTP requests execute
2. **Fiber reactor** multiplexes hundreds of HTTP connections
3. **Connection pooling** and HTTP/2 reuse connections efficiently
4. **Callback workers** execute in normal Sidekiq worker threads

## State Management

The processor maintains state through its lifecycle:

- **stopped**: Initial state, not processing requests
- **running**: Actively processing requests
- **draining**: Not accepting new requests, completing in-flight
- **stopping**: Shutting down, waiting for requests to finish

## Crash Recovery

In-flight requests are persisted to Redis. If a Sidekiq process crashes:

1. Inflight registry serializes pending requests
2. On restart, processor re-enqueues them
3. Requests continue from where they left off
4. Prevents lost work during deployments or crashes

## Configuration

All behavior is controlled through a central `Configuration` object:

- Queue capacity limits
- Request timeouts
- Retry policies
- Logging
- Metrics collection

## Web UI

Optional Sidekiq Web integration provides:

- Real-time metrics dashboard
- In-flight request monitoring
- Historical statistics
- Health indicators

## Thread Safety

- **Thread-safe queues**: `Thread::Queue` for request enqueueing
- **Atomic operations**: `Concurrent::AtomicReference` for state
- **Synchronized access**: Mutexes protect shared data structures
- **Immutable values**: Request/Response are immutable once created
