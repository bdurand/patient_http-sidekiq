# frozen_string_literal: true

require "uri"

module Sidekiq
  module AsyncHttp
    # Configuration for the async HTTP processor.
    #
    # This class holds all configuration options for the Sidekiq Async HTTP gem,
    # including connection limits, timeouts, and other HTTP client settings.
    class Configuration
      # Default threshold in bytes above which payloads are stored externally
      DEFAULT_PAYLOAD_STORE_THRESHOLD = 100_000
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
      attr_reader :connection_pool_size

      # @return [Numeric, nil] Connection timeout in seconds
      attr_reader :connection_timeout

      # @return [String, nil] HTTP/HTTPS proxy URL (supports authentication)
      attr_reader :proxy_url

      # @return [Integer] Number of retries for failed requests
      attr_reader :retries

      # @return [Integer] Size threshold in bytes for external payload storage
      attr_reader :payload_store_threshold

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
      # @param connection_pool_size [Integer] Maximum number of host clients to pool
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
        connection_pool_size: 100,
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
        self.connection_pool_size = connection_pool_size
        self.connection_timeout = connection_timeout
        self.proxy_url = proxy_url
        self.retries = retries

        # Initialize payload store configuration
        @payload_stores = {}
        @default_payload_store_name = nil
        @payload_store_threshold = DEFAULT_PAYLOAD_STORE_THRESHOLD
        @payload_store_mutex = Mutex.new
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

      def connection_pool_size=(value)
        validate_positive_integer(:connection_pool_size, value)
        @connection_pool_size = value
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

      # Register a payload store for external storage of large payloads.
      #
      # Multiple stores can be registered for migration purposes. The last
      # store registered becomes the default used for new writes. References
      # to other registered stores remain valid for reading.
      #
      # @param name [Symbol, String] Unique name for this store registration
      # @param adapter [Symbol, String] The adapter type (:file, :redis, :s3, etc.)
      # @param options [Hash] Options passed to the adapter constructor
      # @return [void]
      # @raise [ArgumentError] If the adapter is not registered
      #
      # @example Register a file store for development
      #   config.register_payload_store(:dev, :file, directory: "/tmp/payloads")
      #
      # @example Migration: register both old and new stores
      #   config.register_payload_store(:old_redis, :redis, url: old_url)
      #   config.register_payload_store(:new_redis, :redis, url: new_url)  # becomes default
      def register_payload_store(name, adapter, **options)
        name = name.to_sym
        adapter = adapter.to_sym

        # Validate adapter exists
        unless PayloadStore::Base.lookup(adapter)
          raise ArgumentError, "Unknown payload store adapter: #{adapter.inspect}. " \
            "Available adapters: #{PayloadStore::Base.registered_adapters.inspect}"
        end

        store = PayloadStore::Base.create(adapter, **options)

        @payload_store_mutex.synchronize do
          @payload_stores[name] = store
          @default_payload_store_name = name
        end
      end

      # Get a registered payload store by name.
      #
      # @param name [Symbol, String, nil] Store name. If nil, returns the default store.
      # @return [PayloadStore::Base, nil] The store instance or nil if not found
      def payload_store(name = nil)
        @payload_store_mutex.synchronize do
          if name.nil?
            return nil unless @default_payload_store_name

            @payload_stores[@default_payload_store_name]
          else
            @payload_stores[name.to_sym]
          end
        end
      end

      # Get the name of the default payload store.
      #
      # @return [Symbol, nil] The default store name or nil if none registered
      def default_payload_store_name
        @payload_store_mutex.synchronize do
          @default_payload_store_name
        end
      end

      # Get all registered payload stores.
      #
      # @return [Hash{Symbol => PayloadStore::Base}] Copy of registered stores
      def payload_stores
        @payload_store_mutex.synchronize do
          @payload_stores.dup
        end
      end

      # Set the threshold size for external payload storage.
      #
      # Payloads larger than this size (in bytes) will be stored externally
      # when a payload store is configured.
      #
      # @param value [Integer] Threshold in bytes
      # @raise [ArgumentError] If value is not a positive integer
      def payload_store_threshold=(value)
        validate_positive_integer(:payload_store_threshold, value)
        @payload_store_threshold = value
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
          "connection_pool_size" => connection_pool_size,
          "connection_timeout" => connection_timeout,
          "proxy_url" => proxy_url,
          "retries" => retries,
          "payload_store_threshold" => payload_store_threshold,
          "payload_stores" => payload_stores.keys,
          "default_payload_store" => default_payload_store_name
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
