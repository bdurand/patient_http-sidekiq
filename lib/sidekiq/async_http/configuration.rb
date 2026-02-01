# frozen_string_literal: true

require "uri"

module Sidekiq
  module AsyncHttp
    # Configuration for the async HTTP processor.
    #
    # This class holds all configuration options for the Sidekiq Async HTTP gem,
    # including connection limits, timeouts, and other HTTP client settings.
    class Configuration
      # @return [Integer] Maximum number of concurrent connections
      attr_reader :max_connections

      # @return [Numeric] Idle connection timeout in seconds
      attr_reader :idle_connection_timeout

      # @return [Numeric] Default request timeout in seconds
      attr_reader :request_timeout

      # @return [Numeric] Graceful shutdown timeout in seconds
      attr_reader :shutdown_timeout

      # @return [Integer] Maximum response size in bytes
      attr_reader :max_response_size

      # @return [Numeric] Heartbeat update interval in seconds
      attr_reader :heartbeat_interval

      # @return [Numeric] Orphan detection threshold in seconds
      attr_reader :orphan_threshold

      # @return [String, nil] Default User-Agent header value
      attr_accessor :user_agent

      # @return [Boolean] Whether to raise HttpError for non-2xx responses by default
      attr_accessor :raise_error_responses

      # @return [Integer] Maximum number of redirects to follow (0 disables redirects)
      attr_reader :max_redirects

      # @return [Hash, nil] Sidekiq options to apply to RequestWorker and CallbackWorker
      attr_reader :sidekiq_options

      # @return [Integer] Maximum number of host clients to pool
      attr_reader :max_host_clients

      # @return [Numeric, nil] Connection timeout in seconds
      attr_reader :connection_timeout

      # @return [String, nil] HTTP/HTTPS proxy URL (supports authentication)
      attr_reader :proxy_url

      # @return [Integer] Number of retries for failed requests
      attr_reader :retries

      # Initializes a new Configuration with the specified options.
      #
      # @param max_connections [Integer] Maximum number of concurrent connections
      # @param idle_connection_timeout [Numeric] Idle connection timeout in seconds
      # @param request_timeout [Numeric] Default request timeout in seconds
      # @param shutdown_timeout [Numeric] Graceful shutdown timeout in seconds
      # @param logger [Logger, nil] Logger instance to use
      # @param max_response_size [Integer] Maximum response size in bytes
      # @param heartbeat_interval [Integer] Interval for updating inflight request heartbeats in seconds
      # @param orphan_threshold [Integer] Age threshold for detecting orphaned requests in seconds
      # @param user_agent [String, nil] Default User-Agent header value
      # @param raise_error_responses [Boolean] Whether to raise HttpError for non-2xx responses by default
      # @param max_redirects [Integer] Maximum number of redirects to follow (0 disables redirects)
      # @param sidekiq_options [Hash, nil] Sidekiq options to apply to RequestWorker and CallbackWorker
      # @param max_host_clients [Integer] Maximum number of host clients to pool
      # @param connection_timeout [Numeric, nil] Connection timeout in seconds
      # @param proxy_url [String, nil] HTTP/HTTPS proxy URL (supports authentication)
      # @param retries [Integer] Number of retries for failed requests
      def initialize(
        max_connections: 256,
        idle_connection_timeout: 60,
        request_timeout: 60,
        shutdown_timeout: (Sidekiq.default_configuration[:timeout] || 25) - 2,
        logger: nil,
        max_response_size: 1024 * 1024,
        heartbeat_interval: 60,
        orphan_threshold: 300,
        user_agent: "Sidekiq-AsyncHttp",
        raise_error_responses: false,
        max_redirects: 5,
        sidekiq_options: nil,
        max_host_clients: 100,
        connection_timeout: nil,
        proxy_url: nil,
        retries: 3
      )
        self.max_connections = max_connections
        self.idle_connection_timeout = idle_connection_timeout
        self.request_timeout = request_timeout
        self.shutdown_timeout = shutdown_timeout
        self.logger = logger
        self.max_response_size = max_response_size
        self.heartbeat_interval = heartbeat_interval
        self.orphan_threshold = orphan_threshold
        self.user_agent = user_agent
        self.raise_error_responses = raise_error_responses
        self.max_redirects = max_redirects
        self.sidekiq_options = sidekiq_options
        self.max_host_clients = max_host_clients
        self.connection_timeout = connection_timeout
        self.proxy_url = proxy_url
        self.retries = retries
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

      def request_timeout=(value)
        validate_positive(:request_timeout, value)
        @request_timeout = value
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

      def max_redirects=(value)
        validate_non_negative_integer(:max_redirects, value)
        @max_redirects = value
      end

      def sidekiq_options=(options)
        if options.nil?
          @sidekiq_options = nil
          return
        end

        unless options.is_a?(Hash)
          raise ArgumentError.new("sidekiq_options must be a Hash, got: #{options.class}")
        end

        @sidekiq_options = options
        apply_sidekiq_options(options)
      end

      def max_host_clients=(value)
        validate_positive_integer(:max_host_clients, value)
        @max_host_clients = value
      end

      def connection_timeout=(value)
        if value.nil?
          @connection_timeout = nil
          return
        end

        validate_positive(:connection_timeout, value)
        @connection_timeout = value
      end

      def proxy_url=(value)
        if value.nil?
          @proxy_url = nil
          return
        end

        validate_url(:proxy_url, value)
        @proxy_url = value
      end

      def retries=(value)
        validate_non_negative_integer(:retries, value)
        @retries = value
      end

      # Convert to hash for inspection
      # @return [Hash] hash representation with string keys
      def to_h
        {
          "max_connections" => max_connections,
          "idle_connection_timeout" => idle_connection_timeout,
          "request_timeout" => request_timeout,
          "shutdown_timeout" => shutdown_timeout,
          "logger" => logger,
          "max_response_size" => max_response_size,
          "heartbeat_interval" => heartbeat_interval,
          "orphan_threshold" => orphan_threshold,
          "user_agent" => user_agent,
          "raise_error_responses" => raise_error_responses,
          "max_redirects" => max_redirects,
          "sidekiq_options" => sidekiq_options,
          "max_host_clients" => max_host_clients,
          "connection_timeout" => connection_timeout,
          "proxy_url" => proxy_url,
          "retries" => retries
        }
      end

      private

      def validate_positive(attribute, value)
        return if value.is_a?(Numeric) && value > 0

        raise ArgumentError.new("#{attribute} must be a positive number, got: #{value.inspect}")
      end

      def validate_non_negative_integer(attribute, value)
        return if value.is_a?(Integer) && value >= 0

        raise ArgumentError.new("#{attribute} must be a non-negative integer, got: #{value.inspect}")
      end

      def validate_positive_integer(attribute, value)
        return if value.is_a?(Integer) && value > 0

        raise ArgumentError.new("#{attribute} must be a positive integer, got: #{value.inspect}")
      end

      def validate_url(attribute, value)
        uri = URI.parse(value)
        return if uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

        raise ArgumentError.new("#{attribute} must be an HTTP or HTTPS URL, got: #{value.inspect}")
      rescue URI::InvalidURIError
        raise ArgumentError.new("#{attribute} must be a valid URL, got: #{value.inspect}")
      end

      def validate_heartbeat_and_threshold
        return unless @heartbeat_interval && @orphan_threshold

        return unless @heartbeat_interval >= @orphan_threshold

        raise ArgumentError.new("heartbeat_interval (#{@heartbeat_interval}) must be less than orphan_threshold (#{@orphan_threshold})")
      end

      def apply_sidekiq_options(options)
        Sidekiq::AsyncHttp::RequestWorker.sidekiq_options(options)
        Sidekiq::AsyncHttp::CallbackWorker.sidekiq_options(options)
      end
    end
  end
end
