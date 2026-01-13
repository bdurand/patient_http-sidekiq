# SidekiqAsyncHttp

:construction: NOT RELEASED :construction:

[![Continuous Integration](https://github.com/bdurand/sidekiq-async_http_requests/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/sidekiq-async_http_requests/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/sidekiq-async_http_requests.svg)](https://badge.fury.io/rb/sidekiq-async_http_requests)

Offload HTTP requests from Sidekiq workers to a dedicated async I/O processor, freeing worker threads immediately.

## Architecture

The gem uses two key classes for handling async HTTP requests:

- **Request**: Contains HTTP-specific parameters (method, URL, headers, body, timeout)
- **RequestTask**: Wraps a Request with callback and job context needed for async processing (job ID, worker classes, timing information)

The Processor accepts `RequestTask` objects via its `enqueue` method, executes the HTTP request asynchronously, and invokes success or error callback workers with the results.

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
