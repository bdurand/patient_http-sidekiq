# frozen_string_literal: true

module TestWorkers
  class Worker
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

  class SuccessWorker
    include Sidekiq::Job

    @calls = []
    @mutex = Mutex.new

    class << self
      attr_reader :calls

      def reset_calls!
        @mutex.synchronize { @calls = [] }
      end

      def record_call(response, *args)
        @mutex.synchronize { @calls << [response, *args] }
      end
    end

    def perform(response_hash, *args)
      response = Sidekiq::AsyncHttp::Response.from_hash(response_hash)
      self.class.record_call(response, *args)
    end
  end

  class ErrorWorker
    include Sidekiq::Job

    @calls = []
    @mutex = Mutex.new

    class << self
      attr_reader :calls

      def reset_calls!
        @mutex.synchronize { @calls = [] }
      end

      def record_call(error, *args)
        @mutex.synchronize { @calls << [error, *args] }
      end
    end

    def perform(error_hash, *args)
      error = Sidekiq::AsyncHttp::Error.from_hash(error_hash)
      self.class.record_call(error, *args)
    end
  end
end
