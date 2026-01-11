# frozen_string_literal: true

module Sidekiq::AsyncHttp
  module TimeHelper
    extend self

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def wall_clock_time(monotonic_timestamp)
      now = Time.now
      elapsed = monotonic_time - monotonic_timestamp
      now - elapsed
    end
  end
end
