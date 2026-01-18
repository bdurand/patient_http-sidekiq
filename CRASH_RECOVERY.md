# Crash Recovery Feature

## Overview

The crash recovery feature provides automatic re-enqueuing of HTTP requests that were popped from the Sidekiq queue but failed to complete due to process crashes (e.g., `kill -9`), network errors, or other unexpected failures.

## Architecture

### Components

1. **InflightRegistry** (`lib/sidekiq/async_http/inflight_registry.rb`)
   - Tracks all in-flight HTTP requests in Redis
   - Provides distributed garbage collection with locking
   - Handles automatic re-enqueuing of orphaned requests

2. **Monitor Thread** (in `Processor`)
   - Runs in the background while the processor is active
   - Updates heartbeats for all in-flight requests every minute (configurable)
   - Attempts garbage collection of orphaned requests every minute

3. **Redis Data Structures**
   - **Sorted Set** (`sidekiq:async_http:inflight_index`): Stores request IDs with timestamps as scores for efficient time-based queries
   - **Hash** (`sidekiq:async_http:inflight_jobs`): Stores the full Sidekiq job payloads for re-enqueuing
   - **Lock Key** (`sidekiq:async_http:gc_lock`): Ensures only one process performs garbage collection at a time

### Configuration

Two new configuration options are available:

```ruby
Sidekiq::AsyncHttp.configure do |config|
  config.heartbeat_interval = 60  # Seconds between heartbeat updates (default: 60)
  config.orphan_threshold = 300   # Seconds before a request is considered orphaned (default: 300)
end
```

**Important constraints:**
- `heartbeat_interval` must be less than `orphan_threshold` (enforced by validation)
- The inflight data TTL is automatically set to 3× the `orphan_threshold` (minimum 1 hour)
- The GC lock TTL is automatically set to 2× the `heartbeat_interval` (minimum 2 minutes)

These dynamic TTLs ensure that:
- Inflight tracking data persists long enough to detect orphaned requests
- The GC lock doesn't expire while a heartbeat update is in progress
- Memory usage is bounded even if the monitor thread stops running

### Workflow

1. **Request Registration**: When a request is enqueued for processing, it's registered in Redis with the current timestamp
2. **Heartbeat Updates**: Every `heartbeat_interval` seconds, the monitor thread updates timestamps for all in-flight requests
3. **Orphan Detection**: The monitor thread queries Redis for requests with timestamps older than `orphan_threshold`
4. **Re-enqueuing with Race Protection**: For each orphaned request:
   - Check the current timestamp (heartbeat may have updated)
   - If still orphaned, remove from Redis and re-enqueue to Sidekiq
   - If heartbeat was updated, skip to prevent duplicate processing
5. **Distributed Locking**: Only one process performs garbage collection at a time using Redis SET with NX/EX options

### Lock Implementation

The implementation uses Redis's native commands with optimistic locking:

- **Lock Acquisition**: Uses `SET key value NX EX ttl` for atomic lock acquisition
- **Lock Release**: Uses `WATCH/MULTI/EXEC` pattern to safely release only if the lock is still held by this process

The orphan removal logic is implemented in Ruby rather than Lua for simplicity and better testability. The distributed garbage collection lock ensures only one process performs cleanup at a time, preventing race conditions.

## Reliability Features

### Race Condition Prevention

- **Heartbeat Race**: If a heartbeat update occurs between finding orphaned requests and checking their timestamps, the Ruby code will detect the updated timestamp and skip re-enqueuing
- **Distributed Locking**: Prevents multiple processes from simultaneously performing garbage collection
- **Lock Identifiers**: Each process uses a unique identifier (`hostname:pid:random`) to safely release only its own locks

The implementation intentionally uses Ruby for orphan checking rather than Lua scripts, as the distributed lock already prevents concurrent cleanup attempts and the simpler Ruby code is more maintainable and testable.

### Error Handling

- **Individual Request Failures**: If re-enqueuing one request fails, other orphaned requests are still processed
- **Graceful Shutdown**: Monitor thread stops cleanly when processor shuts down

## Testing

### Unit Tests

- Located in `spec/sidekiq/async_http/inflight_registry_spec.rb`
- Tests all core functionality with MockRedis
- Fast execution without requiring a real Redis instance

### Integration Tests

- Located in `spec/integration/crash_recovery_spec.rb`
- Tests full workflow including monitor thread and automatic garbage collection
- Can run with either MockRedis or real Redis (both are supported)

## Performance Considerations

- **Monitor Overhead**: Minimal - runs every 60 seconds by default, updating only in-flight request timestamps
- **Garbage Collection**: O(n) where n is number of orphaned requests, typically very small
- **Redis Memory**: Automatically expires inflight data structures based on configuration:
  - Inflight TTL: 3× `orphan_threshold` (minimum 1 hour)
  - GC Lock TTL: 2× `heartbeat_interval` (minimum 2 minutes)
- **No Lua Scripts**: Uses native Redis commands (`SET NX EX`, `WATCH/MULTI/EXEC`) that work with MockRedis

## Migration Notes

This feature is **opt-in via registration** - only requests that are explicitly registered will be tracked for crash recovery. The existing codebase already calls `register` when processing requests, so no migration is needed.

## Monitoring

The feature logs the following events:

- **INFO**: When an orphaned request is successfully re-enqueued
- **ERROR**: When re-enqueuing fails for a specific request

Monitor these logs to track crash recovery activity in production.
