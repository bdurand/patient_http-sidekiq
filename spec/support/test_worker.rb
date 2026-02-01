# frozen_string_literal: true

# Test worker used in shutdown specs.
class TestWorker
  include Sidekiq::Job

  @calls = []
  @mutex = Mutex.new

  class << self
    attr_reader :calls

    def reset_calls!
      @mutex.synchronize { @calls = [] }
    end

    def record_call(*args)
      @mutex.synchronize { @calls << args }
    end
  end

  def perform(*args)
    self.class.record_call(*args)
  end
end
