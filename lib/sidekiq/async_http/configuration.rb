# frozen_string_literal: true

module Sidekiq
  module AsyncHttp
    # Configuration for the async HTTP processor
    class Configuration
      attr_reader :max_connections, :idle_connection_timeout,
        :default_request_timeout, :shutdown_timeout, :dns_cache_ttl

      # Create a new Configuration with defaults
      def initialize(
        max_connections: 256,
        idle_connection_timeout: 60,
        default_request_timeout: 30,
        shutdown_timeout: 25,
        logger: nil,
        http2_enabled: true,
        dns_cache_ttl: 300
      )
        self.max_connections = max_connections
        self.idle_connection_timeout = idle_connection_timeout
        self.default_request_timeout = default_request_timeout
        self.shutdown_timeout = shutdown_timeout
        self.logger = logger
        self.http2_enabled = http2_enabled
        self.dns_cache_ttl = dns_cache_ttl
      end

      # Get the logger to use (configured logger or Sidekiq.logger)
      # @return [Logger] the logger instance
      def logger
        @logger || Sidekiq.logger
      end

      def logger=(value)
        @logger = value
      end

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

      def http2_enabled?
        @http2_enabled
      end

      def http2_enabled=(value)
        @http2_enabled = !!value
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
          "http2_enabled" => http2_enabled?,
          "dns_cache_ttl" => dns_cache_ttl
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
