## Coding style

Always include the # frozen_string_literal: true magic comment at the top of each ruby file.

Use `class << self` syntax for defining class methods. instead of `def self.method_name`.

All public methods should have YARD documentation. Include an empty comment line between the method description and the first YARD tag.

This project uses the standardrb style guide. Run `bundle exec standardrb --fix` to automatically fix style issues.

## Testing

Run the test suite with `bundle exec rspec`.

The bundled test app can be started with `bundle exec rake test_app` and stopped with `bundle exec rake test_app:stop`. It requires a docker container running a Redis compatible server via `docker-compose up`.