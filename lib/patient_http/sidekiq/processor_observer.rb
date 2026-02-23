# frozen_string_literal: true

module PatientHttp
  module Sidekiq
    # Procesor Observer that collect stats in Redis for the WebUI and
    # monitors for crashed processes in order to re-enqueue workers.
    class ProcessorObserver < PatientHttp::ProcessorObserver
      attr_reader :task_monitor

      def initialize(processor)
        @processor = processor
        @stats = Stats.new(processor.config)
        @task_monitor = TaskMonitor.new(processor.config)
        @monitor_thread = TaskMonitorThread.new(
          processor.config,
          @task_monitor,
          -> { @processor.inflight_request_ids }
        )
      end

      def start
        @monitor_thread.start
      end

      def stop
        @monitor_thread.stop
        task_monitor.remove_process
      end

      def capacity_exceeded
        @stats.record_capacity_exceeded
      end

      def request_start(request_task)
        task_monitor.register(request_task)
      end

      def request_end(request_task)
        task_monitor.unregister(request_task)
        @stats.record_request(request_task.response&.status, request_task.duration)
      end

      def request_error(error)
        @stats.record_error(error.error_type)
      end
    end
  end
end
