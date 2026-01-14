# frozen_string_literal: true

class StatusAction
  def call(env)
    sidekiq_stats = Sidekiq::Stats.new
    status = ExampleWorker.status.merge(
      inflight: Sidekiq::AsyncHttp.metrics.inflight_count,
      enqueued: sidekiq_stats.enqueued,
      processed: sidekiq_stats.processed,
      failed: sidekiq_stats.failed,
      retry: sidekiq_stats.retry_size
    )

    [
      200,
      {"Content-Type" => "application/json; charset=utf-8"},
      [JSON.generate(status)]
    ]
  end
end
