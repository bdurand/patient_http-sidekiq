# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # TaskHandler for requests executed directly on the local processor
    # without an enqueued Sidekiq job. Requests with scoped Sidekiq options
    # always go through the queue, so the handler only deals with the
    # default RequestWorker options.
    #
    # Retry enqueues a normal RequestWorker job with the original arguments,
    # so the fail-back behavior matches the enqueued path. The sidekiq_job
    # hash is a minimal job record kept for the crash-recovery registry; it
    # has no jid because no Sidekiq job exists until the request is
    # re-enqueued, so job_id returns nil.
    class DirectTaskHandler < TaskHandler
      # @param args [Array] the RequestWorker job arguments
      def initialize(args)
        @args = args
        super(minimal_job_record)
      end

      # Re-enqueue the request as a normal RequestWorker job.
      #
      # @return [String] the job ID
      def retry
        PatientHttp::Sidekiq.with_redis_pool do
          RequestWorker.perform_async(*@args)
        end
      end

      private

      # Minimal pushable job record for the crash-recovery registry.
      # TaskMonitor serializes it to Redis and the orphan GC pushes it
      # verbatim, possibly from another process, so it cannot enqueue
      # through this handler. The worker options are included because
      # Sidekiq::Client.push does not apply them when "class" is a String.
      #
      # @return [Hash]
      def minimal_job_record
        RequestWorker.get_sidekiq_options
          .merge("class" => RequestWorker.name, "args" => @args)
      end
    end
  end
end
