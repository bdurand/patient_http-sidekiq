# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.4.0

### Added

- Dedicated Redis connection pool for the gem's own threads (`redis_pool_size`, default automatic; `redis_pool_timeout`, default 5 seconds). Registry writes, stats, and job pushes made from the processor's completion worker threads and the monitor thread no longer go through Sidekiq's small internal pool, which was a serialization point under load and could time out and lose completions.
- Named processors: declare profiles with `config.processor(:llm, max_connections: 200)` and route requests with `PatientHttp::Sidekiq.execute(request, processor: :llm)`, a `processor:` option on the request itself, or `with_sidekiq_options("processor" => "llm")`. Each profile runs as an independent processor with its own capacity, timeouts, and threads, so one workload class cannot starve another. The processor name is serialized into the job arguments, so retries and crash recovery keep their routing. Jobs from older gem versions run on the `:default` processor.
- Local stats aggregation (`stats_flush_interval`, default 5 seconds; 0 restores synchronous writes). Request metrics accumulate in memory and flush to Redis in one pipelined write per interval, removing the per-request write to the shared totals hash key. `get_totals` reports per-processor requests, duration, errors, and capacity rejections when more than one profile is configured.
- A result that can never be delivered no longer keeps its crash-recovery record. Delivery is retried and then recovered as before, but a failure that means the result cannot be serialized (`JSON::GeneratorError` and the `Encoding` errors, in the failure or in its cause chain) is permanent: the request is counted as an `undeliverable_result` error and its job is moved to the Sidekiq dead set. Such a request previously stayed in the registry, counted as in flight, and was re-enqueued and failed again after every process restart.
- The Web UI dashboard reports the high-water mark of requests in flight for each processor. The count only rises when a processor accepts a request, so the mark is recorded exactly rather than sampled, and it costs one comparison in memory. It is the most requests one process held at once, so it compares with `max_connections`, which is also per process. Like the other statistics it covers everything since they were last cleared.
- The Web UI dashboard lists the requests that have been in flight the longest, with the URL, HTTP method, processor, and age of each. The details are written next to the crash-recovery record, so a request left behind by a process that died stays listed until the orphan collector re-enqueues it. The URL is sanitized first: the user name, password, query string, and fragment are removed. Use `config.inflight_url_sanitizer` to redact more, or `config.inflight_details = false` to record nothing.
- The Web UI dashboard breaks the statistics down by processor when more than one profile is configured, reporting each processor's inflight requests, capacity, utilization, requests, errors, capacity rejections, and average duration. Each process publishes the capacity of its processors with its heartbeat, which the monitor thread now sends on every pass so the inflight counts stay current.
- Capacity fast path: requests are rejected with a cheap in-memory capacity check before any Redis registration. A rejection previously cost three Redis round trips (register, unregister, stat); it now costs none.
- The `completion_failed` processor event is handled by keeping the crash-recovery registry entry, so a request whose result could not be delivered is re-enqueued by the orphan collector instead of being silently lost, unless the failure is permanent (see above). Requires patient_http 1.5.0.
- A warning is logged at startup when the hiredis Redis driver is detected, because its blocking I/O can stall the reactor thread if application code calls Redis from processor callbacks.

### Changed

- The orphan collector removes orphans in batches of 100 with a single Lua call per batch (invoked by `EVALSHA`), instead of one `EVAL` with the full script body per orphan. Releasing the collector's lock is now a single compare-and-delete script call instead of a WATCH/GET/MULTI sequence.
- The shutdown re-enqueue path no longer unregisters a task twice or records a completion stat for a request that never completed.
- The task monitor thread and stats are now shared across all processors in the process; `ProcessorObserver.new` takes `stats:` and `task_monitor:` keyword arguments.
- The `patient_http` dependency floor is now 1.5.0.

## 1.3.0

### Added

- Requests made in a process with a running processor now go straight to the processor instead of being enqueued through Sidekiq. The request can always be re-enqueued as a normal `RequestWorker` job, so all of the re-enqueue paths (processor shutdown, crash recovery, and the at-capacity fallback) behave the same as the enqueued path. Requests made in a `with_sidekiq_options` block always go through the Sidekiq queue, so that Sidekiq applies the options; options set with `config.sidekiq_options` do not apply to direct-executed requests because no Sidekiq job is created. The new `direct_execution` configuration option (default: `true`) turns this behavior off.

### Changed

- Requests are now registered in the crash-recovery registry when the processor accepts them, before the enqueue call returns, instead of when the request starts processing. A request handed to the processor is durable from that point on, and heartbeats now cover queued requests as well as in-flight ones. The entry is removed when the request completes or when a Sidekiq job owns the request again. A failure to write the registry entry rejects the request and raises to the caller, the same as a failed enqueue. This requires patient_http 1.4.0.

## 1.2.0

### Added

- `PatientHttp::Sidekiq.with_sidekiq_options` sets Sidekiq job options (queue, retry, etc.) at runtime for the requests enqueued within a block. When the options include a queue, the callback job for the request is enqueued on that queue as well.

## 1.1.2

### Fixed

- The Web UI stylesheet now loads on Sidekiq 7.x. The `style_tag` helper returns the link tag on Sidekiq 7 but adds it to the page head on Sidekiq 8; the view now handles both.
- The Web UI stylesheet now uses CSS variables that the Sidekiq 8 web UI actually defines (`--color-primary`, `--color-text`, ...), with static fallback values for Sidekiq 7.x.

## 1.1.1

### Fixed

- The Sidekiq Web UI extension now registers correctly on Sidekiq 7.3. It previously raised `NoMethodError: undefined method 'register_extension' for class Sidekiq::Web` because that method only exists in Sidekiq 8.
- The Web UI dashboard page now renders on Sidekiq versions before 8.1. Those versions resolve view files as `*.erb` instead of `*.html.erb`, so the template is now rendered from a string.
- Requiring the Web UI on Sidekiq versions before 7.3 now raises a `LoadError` with a clear message instead of an obscure error.

### Added

- `require "patient_http/sidekiq/web"` can now be used to load the Web UI extension, matching the `require "sidekiq/web"` convention. The previous `patient_http/sidekiq/web_ui` path still works.

## 1.1.0

### Changed

- `PatientHttp::Sidekiq.configure` now sets the built configuration as the `PatientHttp.default_configuration` so that secrets registered at the module level with `PatientHttp.register_secret` are applied to the configuration the processor runs with, regardless of boot order. This requires patient_http 1.3.0 or newer.

## 1.0.2

### Fixed

- Crash recovery now recovers requests from crashed processes. Previously a crashed process's ID remained in the process registry indefinitely, permanently excluding its in-flight requests from orphan detection unless the Sidekiq Web UI happened to prune it.
- Fixed calls to nonexistent `Sidekiq.testing?` in error handlers, which would raise `NoMethodError` and permanently kill the task monitor thread on the first transient Redis error.
- Externally stored request payloads are no longer deleted as soon as the request is submitted to the processor. They are now retained until the request completes so that Sidekiq retries, shutdown re-enqueues, and crash recovery can still fetch them. Dead `RequestWorker` jobs clean up their stored payloads when retries are exhausted.
- `CallbackWorker` no longer deletes externally stored payloads when the callback raises, so Sidekiq retries can fetch the payload and re-run the callback.
- Fixed dead job payload cleanup in `CallbackWorker`, which silently failed by calling a nonexistent method.
- `PatientHttp::Sidekiq.configure` and `reset_configuration!` now reset the memoized external storage so it picks up the new configuration.
- Heartbeat updates now refresh the TTL on the inflight tracking keys so they cannot expire while long-running requests are still in flight.
- Fixed race conditions that could create duplicate processors or task monitor threads from concurrent lifecycle calls; starting while the processor is draining no longer replaces it.

## 1.0.1

### Fixed

- Ensure `PatientHttp::Sidekiq` is automatically registered as the HTTP processor on a process not running the Sidekiq server. This gem will now auto register itself on a client process either by calling `PatientHttp::Sidekiq.configure` or `PatientHttp::Sidekiq.register_handler` directly.

## 1.0.0

### Added

- Dedicated async HTTP processor thread for Sidekiq to avoid blocking worker threads during in-flight requests.
- `PatientHttp::Sidekiq` API with convenience methods for common HTTP verbs (`get`, `post`, `put`, `patch`, and `delete`).
- Callback-based completion and error handling via `on_complete` and `on_error`, executed as Sidekiq jobs.
- Support for callback context via `callback_args`, available from response and error objects.
- Built-in runtime visibility with task monitoring and a Sidekiq Web UI page for async HTTP activity.
- Crash/failure recovery with heartbeat-based orphan detection and automatic re-enqueue of interrupted requests.
