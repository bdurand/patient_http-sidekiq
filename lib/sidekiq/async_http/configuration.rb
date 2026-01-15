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

      # @return [Integer] DNS cache TTL in seconds
      attr_reader :dns_cache_ttl

      # @return [Integer] Maximum response size in bytes
      attr_reader :max_response_size

      # @return [String, nil] Default User-Agent header value
      attr_accessor :user_agent

      # Initializes a new Configuration with the specified options.
      #
      # @param max_connections [Integer] Maximum number of concurrent connections
      # @param idle_connection_timeout [Integer] Idle connection timeout in seconds
      # @param default_request_timeout [Integer] Default request timeout in seconds
      # @param shutdown_timeout [Integer] Graceful shutdown timeout in seconds
      # @param logger [Logger, nil] Logger instance to use
      # @param dns_cache_ttl [Integer] DNS cache TTL in seconds
      # @param max_response_size [Integer] Maximum response size in bytes
      # @param user_agent [String, nil] Default User-Agent header value
      def initialize(
        max_connections: 256,
        idle_connection_timeout: 60,
        default_request_timeout: 60,
        shutdown_timeout: 25,
        logger: nil,
        dns_cache_ttl: 300,
        max_response_size: 10 * 1024 * 1024,
        user_agent: nil
      )
        self.max_connections = max_connections
        self.idle_connection_timeout = idle_connection_timeout
        self.default_request_timeout = default_request_timeout
        self.shutdown_timeout = shutdown_timeout
        self.logger = logger
        self.dns_cache_ttl = dns_cache_ttl
        self.max_response_size = max_response_size
        self.user_agent = user_agent
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

      def dns_cache_ttl=(value)
        validate_positive(:dns_cache_ttl, value)
        @dns_cache_ttl = value
      end

      def max_response_size=(value)
        validate_positive(:max_response_size, value)
        @max_response_size = value
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
          "dns_cache_ttl" => dns_cache_ttl,
          "max_response_size" => max_response_size,
          "user_agent" => user_agent
        }
      end

      private

      def validate_positive(attribute, value)
        unless value.is_a?(Numeric) && value > 0
          raise ArgumentError, "#{attribute} must be a positive number, got: #{value.inspect}"
        end
      end
    end
  end
end
