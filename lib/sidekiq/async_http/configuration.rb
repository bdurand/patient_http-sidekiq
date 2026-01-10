# frozen_string_literal: true

module Sidekiq
  module AsyncHttp
    # Configuration for the async HTTP processor
    class Configuration < Data.define(
      :max_connections,
      :idle_connection_timeout,
      :default_request_timeout,
      :shutdown_timeout,
      :logger,
      :enable_http2,
      :dns_cache_ttl,
      :backpressure_strategy
    )
      # Valid backpressure strategies
      VALID_BACKPRESSURE_STRATEGIES = %i[block raise drop_oldest].freeze

      # Create a new Configuration with defaults
      def initialize(
        max_connections: 256,
        idle_connection_timeout: 60,
        default_request_timeout: 30,
        shutdown_timeout: 25,
        logger: nil,
        enable_http2: true,
        dns_cache_ttl: 300,
        backpressure_strategy: :raise
      )
        super
      end

      # Validate the configuration
      # @raise [ArgumentError] if configuration is invalid
      # @return [Configuration] self for chaining
      def validate!
        validate_positive(:max_connections)
        validate_positive(:idle_connection_timeout)
        validate_positive(:default_request_timeout)
        validate_positive(:shutdown_timeout)
        validate_positive(:dns_cache_ttl)
        validate_backpressure_strategy

        self
      end

      # Get the logger to use (configured logger or Sidekiq.logger)
      # @return [Logger] the logger instance
      def effective_logger
        logger || (defined?(Sidekiq) && Sidekiq.logger)
      end

      # Convert to hash for inspection
      # @return [Hash] hash representation with string keys
      def to_h
        {
          "max_connections" => max_connections,
          "idle_connection_timeout" => idle_connection_timeout,
          "default_request_timeout" => default_request_timeout,
          "shutdown_timeout" => shutdown_timeout,
          "logger" => logger.inspect,
          "enable_http2" => enable_http2,
          "dns_cache_ttl" => dns_cache_ttl,
          "backpressure_strategy" => backpressure_strategy.to_s
        }
      end

      private

      def validate_positive(attribute)
        value = public_send(attribute)
        unless value.is_a?(Numeric) && value > 0
          raise ArgumentError, "#{attribute} must be a positive number, got: #{value.inspect}"
        end
      end

      def validate_backpressure_strategy
        unless VALID_BACKPRESSURE_STRATEGIES.include?(backpressure_strategy)
          raise ArgumentError,
            "backpressure_strategy must be one of #{VALID_BACKPRESSURE_STRATEGIES.inspect}, " \
            "got: #{backpressure_strategy.inspect}"
        end
      end
    end

    # Builder for creating Configuration instances via DSL
    class Builder
      attr_accessor :max_connections, :idle_connection_timeout, :default_request_timeout,
        :shutdown_timeout, :logger, :enable_http2, :dns_cache_ttl, :backpressure_strategy

      def initialize
        @max_connections = 256
        @idle_connection_timeout = 60
        @default_request_timeout = 30
        @shutdown_timeout = 25
        @logger = nil
        @enable_http2 = true
        @dns_cache_ttl = 300
        @backpressure_strategy = :raise
      end

      # Build and validate the configuration
      # @return [Configuration] the immutable configuration
      def build
        Configuration.new(
          max_connections: @max_connections,
          idle_connection_timeout: @idle_connection_timeout,
          default_request_timeout: @default_request_timeout,
          shutdown_timeout: @shutdown_timeout,
          logger: @logger,
          enable_http2: @enable_http2,
          dns_cache_ttl: @dns_cache_ttl,
          backpressure_strategy: @backpressure_strategy
        ).validate!
      end
    end
  end
end
