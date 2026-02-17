# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.0.0

### Added

- Dedicated async HTTP processor thread for Sidekiq to avoid blocking worker threads during in-flight requests.
- `Sidekiq::AsyncHttp` API with convenience methods for common HTTP verbs (`get`, `post`, `put`, `patch`, and `delete`).
- Callback-based completion and error handling via `on_complete` and `on_error`, executed as Sidekiq jobs.
- Support for callback context via `callback_args`, available from response and error objects.
- Built-in runtime visibility with task monitoring and a Sidekiq Web UI page for async HTTP activity.
- Crash/failure recovery with heartbeat-based orphan detection and automatic re-enqueue of interrupted requests.
