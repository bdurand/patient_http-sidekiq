# frozen_string_literal: true

class StatusAction
  def call(env)
    sidekiq_stats = Sidekiq::Stats.new
    status = ExampleWorker.status.merge(
      enqueued: sidekiq_stats.enqueued,
      processed: sidekiq_stats.processed,
      failed: sidekiq_stats.failed
    )

    [
      200,
      {"Content-Type" => "application/json; charset=utf-8"},
      [JSON.generate(status)]
    ]
  end
end
