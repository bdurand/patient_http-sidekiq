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

      def record_call(response, *args)
        @mutex.synchronize { @calls << [response, *args] }
      end
    end

    def perform(response_hash, *args)
      # Convert hash to Response object for integration tests with complete hashes
      response = if response_hash.is_a?(Hash) && response_hash.key?("status") && response_hash.key?("http_method")
        Sidekiq::AsyncHttp::Response.load(response_hash)
      else
        response_hash # For test_workers_spec simple hashes
      end
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
      # Convert hash to Error object for integration tests with complete hashes
      error = if error_hash.is_a?(Hash) && error_hash.key?("error_type") && error_hash.key?("class_name")
        Sidekiq::AsyncHttp::Error.load(error_hash)
      else
        error_hash # For test_workers_spec simple hashes
      end
      self.class.record_call(error, *args)
    end
  end
end
