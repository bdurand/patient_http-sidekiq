# frozen_string_literal: true

# Encapsulates current Sidekiq and Sidekiq statistics.
class CurrentStats
  attr_reader :inflight, :processors, :busy, :enqueued, :retry, :processed, :failed

  def initialize
    sidekiq_stats = Sidekiq::Stats.new
    @processors = processor_counts
    @inflight = @processors.values.sum { |counts| counts[:inflight] }
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
      processors: @processors,
      busy: @busy,
      enqueued: @enqueued,
      retry: @retry,
      processed: @processed,
      failed: @failed
    }
  end

  private

  # Inflight and capacity counts for each configured processor.
  def processor_counts
    AppConfig.processor_names.each_with_object({}) do |name, counts|
      processor = PatientHttp::Sidekiq.processor(name)
      counts[name] = {
        inflight: processor&.total_count.to_i,
        max_capacity: processor ? processor.config.max_connections : 0
      }
    end
  end
end
