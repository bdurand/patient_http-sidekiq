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

  class WorkerWithClient
    include Sidekiq::AsyncHttp::Job

    async_http_client base_url: "https://example.org", headers: {"X-Custom-Header" => "Test"}

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

    def perform(endpoint)
      response = async_get(endpoint)
      self.class.record_call(response, endpoint)
    end
  end

  class CompletionWorker
    include Sidekiq::Job

    @calls = []
    @mutex = Mutex.new

    class << self
      attr_reader :calls

      def reset_calls!
        @mutex.synchronize { @calls = [] }
      end

      def record_call(response)
        @mutex.synchronize { @calls << [response] }
      end
    end

    def perform(response)
      # Handle case in tests where the Sidekiq middleware is not used.
      response = Sidekiq::AsyncHttp::Response.load(response) if response.is_a?(Hash)
      self.class.record_call(response)
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

      def record_call(error)
        @mutex.synchronize { @calls << [error] }
      end
    end

    def perform(error)
      # Handle case in tests where the Sidekiq middleware is not used.
      error = Sidekiq::AsyncHttp::Error.load(error) if error.is_a?(Hash)
      self.class.record_call(error)
    end
  end
end
