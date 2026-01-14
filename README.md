# SidekiqAsyncHttp

:construction: NOT RELEASED :construction:

[![Continuous Integration](https://github.com/bdurand/sidekiq-async_http_requests/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/sidekiq-async_http_requests/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/sidekiq-async_http_requests.svg)](https://badge.fury.io/rb/sidekiq-async_http_requests)

This gem provides a mechanism to offload HTTP requests spawned by Sidekiq jobs to a dedicated async I/O processor, freeing worker threads immediately.

Sidekiq is designed with the assumption that jobs are short-lived and take milliseconds to complete. Long running HTTP requests will block worker threads from processing other jobs, leading to increased latency and reduced throughput. This is particularly the case if you want to call an LLM or Agentic AI API from a Sidekiq job, where requests can take many seconds to complete.

By using an async HTTP processor, Sidekiq worker threads can enqueue HTTP requests to be processed asynchronously, allowing them to return to the pool and handle other jobs immediately. The async processor uses non-blocking I/O to handle many concurrent HTTP requests efficiently and can scale to thousands of concurrent requests with minimal resource usage.

## Usage

TODO: Write usage instructions here

## Installation

Add this line to your application's Gemfile:

```ruby
gem "sidekiq-async_http_requests"
```

Then execute:
```bash
$ bundle
```

Or install it yourself as:
```bash
$ gem install sidekiq-async_http_requests
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/sidekiq-async_http_requests).

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
