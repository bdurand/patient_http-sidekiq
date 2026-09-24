# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Task handler for requests that run directly on a processor in the
    # current process, without a Sidekiq job. Requests made in a
    # `with_sidekiq_options` block always go through the queue, so this
    # handler uses only the default RequestWorker options.
    #
    # A retry enqueues a RequestWorker job with the original arguments, so a
    # direct request behaves the same as an enqueued one when it's retried.
    # The `sidekiq_job` Hash is a minimal job record for the crash-recovery
    # registry. The record has no job ID because no Sidekiq job exists until
    # the request is re-enqueued, so `job_id` returns `nil`.
    class DirectTaskHandler < TaskHandler
      # Creates a task handler for a request that runs directly.
      #
      # @param args [Array] The RequestWorker job arguments.
      # @param config [PatientHttp::Configuration, nil] The configuration of the
      #   processor that runs the request. If `nil`, uses the base configuration.
      def initialize(args, config: nil)
        @args = args
        super(minimal_job_record, config: config)
      end

      # Enqueues the request as a RequestWorker job.
      #
      # @return [String] The job ID.
      def retry
        PatientHttp::Sidekiq.with_redis_pool do
          RequestWorker.perform_async(*@args)
        end
      end

      private

      # Returns a minimal job record for the crash-recovery registry.
      #
      # TaskMonitor writes the record to Redis. The orphan collector pushes the
      # record to Sidekiq as is, possibly from another process, so the record
      # can't depend on this handler. The record includes the worker options
      # because `Sidekiq::Client.push` doesn't apply them when `class` is
      # a String.
      #
      # @return [Hash] The job record.
      def minimal_job_record
        RequestWorker.get_sidekiq_options
          .merge("class" => RequestWorker.name, "args" => @args)
      end
    end
  end
end
