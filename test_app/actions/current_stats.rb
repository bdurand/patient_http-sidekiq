# frozen_string_literal: true

# Encapsulates current Sidekiq and AsyncHttp statistics.
class CurrentStats
  attr_reader :inflight, :busy, :enqueued, :retry, :processed, :failed

  def initialize
    sidekiq_stats = Sidekiq::Stats.new
    @inflight = Sidekiq::AsyncHttp.metrics&.inflight_count.to_i
    @busy = Sidekiq::ProcessSet.new.reduce(0) { |sum, process| sum + process["busy"].to_i }
    @enqueued = sidekiq_stats.enqueued
    @retry = sidekiq_stats.retry_size
    @processed = sidekiq_stats.processed
    @failed = sidekiq_stats.failed
  end

  # Returns true if there is no current activity (all counters are zero).
  #
  # @return [Boolean]
  def no_activity?
    @inflight == 0 && @busy == 0 && @enqueued == 0 && @retry == 0
  end

  # Returns a hash of all stats.
  #
  # @return [Hash]
  def to_h
    {
      inflight: @inflight,
      busy: @busy,
      enqueued: @enqueued,
      retry: @retry,
      processed: @processed,
      failed: @failed
    }
  end
end
