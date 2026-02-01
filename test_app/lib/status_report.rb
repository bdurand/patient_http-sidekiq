# frozen_string_literal: true

class StatusReport
  class Callback
    def on_complete(_response)
      StatusReport.new("Asynchronous").complete!
    end

    def on_error(_error)
      StatusReport.new("Asynchronous").error!
    end
  end

  def initialize(name)
    @name = name
  end

  def complete!
    Sidekiq.redis do |conn|
      conn.incr("#{@name}_complete")
    end
  end

  def error!
    Sidekiq.redis do |conn|
      conn.incr("#{@name}_error")
    end
  end

  def status
    complete = nil
    error = nil
    Sidekiq.redis do |conn|
      complete = conn.get("#{@name}_complete").to_i
      error = conn.get("#{@name}_error").to_i
    end
    {complete: complete, error: error}
  end

  def reset!
    Sidekiq.redis do |conn|
      conn.del("#{@name}_complete")
      conn.del("#{@name}_error")
    end
  end
end
