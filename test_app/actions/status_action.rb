# frozen_string_literal: true

class StatusAction
  def call(env)
    current_stats = CurrentStats.new
    async_stats = StatusReport.new("AsynchronousWorker").status
    sync_stats = StatusReport.new("SynchronousWorker").status

    status = current_stats.to_h.merge(
      asynchronous: async_stats,
      synchronous: sync_stats
    )

    [
      200,
      {"Content-Type" => "application/json; charset=utf-8"},
      [JSON.generate(status)]
    ]
  end
end
