# frozen_string_literal: true

module Sidekiq
  module AsyncHttp
    # Configuration for the async HTTP processor.
    #
    # This class holds all configuration options for the Sidekiq Async HTTP gem,
    # including connection limits, timeouts, and other HTTP client settings.
    class Configuration
      # @return [Integer] Maximum number of concurrent connections
      attr_reader :max_connections

      # @return [Integer] Idle connection timeout in seconds
      attr_reader :idle_connection_timeout

      # @return [Integer] Default request timeout in seconds
      attr_reader :default_request_timeout

      # @return [Integer] Graceful shutdown timeout in seconds
      attr_reader :shutdown_timeout

      # @return [Integer] Maximum response size in bytes
      attr_reader :max_response_size

      # @return [Integer] Heartbeat update interval in seconds
      attr_reader :heartbeat_interval

      # @return [Integer] Orphan detection threshold in seconds
      attr_reader :orphan_threshold

      # @return [String, nil] Default User-Agent header value
      attr_accessor :user_agent

      # @return [Boolean] Whether to raise HttpError for non-2xx responses by default
      attr_accessor :raise_error_responses

      # Initializes a new Configuration with the specified options.
      #
      # @param max_connections [Integer] Maximum number of concurrent connections
      # @param idle_connection_timeout [Integer] Idle connection timeout in seconds
      # @param default_request_timeout [Integer] Default request timeout in seconds
      # @param shutdown_timeout [Integer] Graceful shutdown timeout in seconds
      # @param logger [Logger, nil] Logger instance to use
      # @param max_response_size [Integer] Maximum response size in bytes
      # @param heartbeat_interval [Integer] Interval for updating inflight request heartbeats in seconds
      # @param orphan_threshold [Integer] Age threshold for detecting orphaned requests in seconds
      # @param user_agent [String, nil] Default User-Agent header value
      # @param raise_error_responses [Boolean] Whether to raise HttpError for non-2xx responses by default
      def initialize(
        max_connections: 256,
        idle_connection_timeout: 60,
        default_request_timeout: 60,
        shutdown_timeout: (Sidekiq.default_configuration[:timeout] || 25) - 2,
        logger: nil,
        max_response_size: 1024 * 1024,
        heartbeat_interval: 60,
        orphan_threshold: 300,
        user_agent: nil,
        raise_error_responses: false
      )
        self.max_connections = max_connections
        self.idle_connection_timeout = idle_connection_timeout
        self.default_request_timeout = default_request_timeout
        self.shutdown_timeout = shutdown_timeout
        self.logger = logger
        self.max_response_size = max_response_size
        self.heartbeat_interval = heartbeat_interval
        self.orphan_threshold = orphan_threshold
        self.user_agent = user_agent
        self.raise_error_responses = raise_error_responses
      end

      # Get the logger to use (configured logger or Sidekiq.logger)
      # @return [Logger] the logger instance
      def logger
        @logger || Sidekiq.logger
      end

      attr_writer :logger

      def max_connections=(value)
        validate_positive(:max_connections, value)
        @max_connections = value
      end

      def idle_connection_timeout=(value)
        validate_positive(:idle_connection_timeout, value)
        @idle_connection_timeout = value
      end

      def default_request_timeout=(value)
        validate_positive(:default_request_timeout, value)
        @default_request_timeout = value
      end

      def shutdown_timeout=(value)
        validate_positive(:shutdown_timeout, value)
        @shutdown_timeout = value
      end

      def max_response_size=(value)
        validate_positive(:max_response_size, value)
        @max_response_size = value
      end

      def heartbeat_interval=(value)
        validate_positive(:heartbeat_interval, value)
        @heartbeat_interval = value
        validate_heartbeat_and_threshold
      end

      def orphan_threshold=(value)
        validate_positive(:orphan_threshold, value)
        @orphan_threshold = value
        validate_heartbeat_and_threshold
      end

      # Convert to hash for inspection
      # @return [Hash] hash representation with string keys
      def to_h
        {
          "max_connections" => max_connections,
          "idle_connection_timeout" => idle_connection_timeout,
          "default_request_timeout" => default_request_timeout,
          "shutdown_timeout" => shutdown_timeout,
          "logger" => logger,
          "max_response_size" => max_response_size,
          "heartbeat_interval" => heartbeat_interval,
          "orphan_threshold" => orphan_threshold,
          "user_agent" => user_agent,
          "raise_error_responses" => raise_error_responses
        }
      end

      private

      def validate_positive(attribute, value)
        return if value.is_a?(Numeric) && value > 0

        raise ArgumentError.new("#{attribute} must be a positive number, got: #{value.inspect}")
      end

      def validate_heartbeat_and_threshold
        return unless @heartbeat_interval && @orphan_threshold

        return unless @heartbeat_interval >= @orphan_threshold

        raise ArgumentError.new("heartbeat_interval (#{@heartbeat_interval}) must be less than orphan_threshold (#{@orphan_threshold})")
      end
    end
  end
end
