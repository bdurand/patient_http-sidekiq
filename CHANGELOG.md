# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
