# frozen_string_literal: true

module Sidekiq
  module AsyncHttp
    # Configuration for the Sidekiq Async HTTP gem.
    #
    # Wraps AsyncHttpPool::Configuration with Sidekiq-aware defaults and adds
    # Sidekiq-specific options like worker queue/retry settings.
    #
    # Access the underlying pool configuration via the +http_pool+ attribute.
    class Configuration < AsyncHttpPool::Configuration
      # Default threshold in bytes above which payloads are stored externally
      DEFAULT_PAYLOAD_STORE_THRESHOLD = 64 * 1024 # 64KB

      # @return [Integer] Size threshold in bytes for external payload storage
      attr_reader :payload_store_threshold

      # @return [Numeric] Orphan detection threshold in seconds
      attr_reader :orphan_threshold

      # @return [Numeric] Heartbeat update interval in seconds
      attr_reader :heartbeat_interval

      # @return [Hash, nil] Sidekiq options to apply to RequestWorker and CallbackWorker
      attr_reader :sidekiq_options

      # @return [#call] The configured encryptor callable
      attr_reader :encryptor

      # @return [#call] The configured decryptor callable
      attr_reader :decryptor

      # Initializes a new Configuration with the specified options.
      #
      # @param heartbeat_interval [Integer] Interval for updating inflight request heartbeats in seconds
      # @param orphan_threshold [Integer] Age threshold for detecting orphaned requests in seconds
      # @param sidekiq_options [Hash, nil] Sidekiq options to apply to RequestWorker and CallbackWorker
      # @param pool_options [Hash] Options passed through to AsyncHttpPool::Configuration.
      #   Sidekiq-aware defaults are applied for shutdown_timeout, user_agent, and logger
      #   if not explicitly provided.
      def initialize(
        heartbeat_interval: 60,
        orphan_threshold: 300,
        sidekiq_options: nil,
        payload_store_threshold: DEFAULT_PAYLOAD_STORE_THRESHOLD,
        **pool_options
      )
        pool_options[:shutdown_timeout] ||= (Sidekiq.default_configuration[:timeout] || 25) - 2
        pool_options[:user_agent] ||= "Sidekiq-AsyncHttp"
        pool_options[:logger] ||= Sidekiq.logger

        super(**pool_options)

        @encryptor = nil
        @decryptor = nil

        self.sidekiq_options = sidekiq_options
        self.heartbeat_interval = heartbeat_interval
        self.orphan_threshold = orphan_threshold
        self.payload_store_threshold = payload_store_threshold || DEFAULT_PAYLOAD_STORE_THRESHOLD
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

      def heartbeat_interval=(value)
        raise ArgumentError.new("heartbeat_interval must be positive, got: #{value.inspect}") unless value.positive?

        @heartbeat_interval = value
        validate_heartbeat_and_threshold
      end

      def orphan_threshold=(value)
        raise ArgumentError.new("orphan_threshold must be positive, got: #{value.inspect}") unless value.positive?

        @orphan_threshold = value
        validate_heartbeat_and_threshold
      end

      # Set Sidekiq worker options and apply them to RequestWorker and CallbackWorker.
      # The options will be applied to both workers. If you want to customize just
      # one of them, set the options directly on that worker class.
      #
      # @param options [Hash, nil] Sidekiq options hash
      # @return [void]
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

      # Set the encryption callable for encrypting payloads before serialization.
      #
      # @param callable [#call, nil] An object that responds to #call, taking data and returning encrypted data
      # @yield [data] A block that takes data and returns encrypted data
      # @raise [ArgumentError] If both callable and block are provided, or if callable doesn't respond to #call
      def encryption(callable = nil, &block)
        @encryptor = resolve_callable(:encryption, callable, &block)
      end

      # Set the decryption callable for decrypting payloads after deserialization.
      #
      # @param callable [#call, nil] An object that responds to #call, taking data and returning decrypted data
      # @yield [data] A block that takes data and returns decrypted data
      # @raise [ArgumentError] If both callable and block are provided, or if callable doesn't respond to #call
      def decryption(callable = nil, &block)
        @decryptor = resolve_callable(:decryption, callable, &block)
      end

      # Encrypt data using the configured encryptor.
      #
      # @param data [Object] the data to encrypt
      # @return [Object] the encrypted data
      def encrypt(data)
        return @encryptor.call(data) if @encryptor

        if defined?(Sidekiq::EncryptedArgs)
          Sidekiq::EncryptedArgs.encrypt(data)
        else
          data
        end
      end

      # Decrypt data using the configured decryptor.
      #
      # @param data [Object] the data to decrypt
      # @return [Object] the decrypted data
      def decrypt(data)
        return @decryptor.call(data) if @decryptor

        if defined?(Sidekiq::EncryptedArgs)
          Sidekiq::EncryptedArgs.decrypt(data)
        else
          data
        end
      end

      # Convert to hash for inspection
      # @return [Hash] hash representation with string keys
      def to_h
        super.merge(
          "payload_store_threshold" => payload_store_threshold,
          "heartbeat_interval" => heartbeat_interval,
          "orphan_threshold" => orphan_threshold,
          "sidekiq_options" => sidekiq_options,
          "encryptor" => !@encryptor.nil?,
          "decryptor" => !@decryptor.nil?
        )
      end

      private

      def resolve_callable(name, callable = nil, &block)
        if callable && block
          raise ArgumentError, "#{name} accepts either a callable argument or a block, not both"
        end

        if callable && !callable.respond_to?(:call)
          raise ArgumentError, "#{name} callable must respond to #call"
        end

        callable || block
      end

      def apply_sidekiq_options(options)
        Sidekiq::AsyncHttp::RequestWorker.sidekiq_options(options)
        Sidekiq::AsyncHttp::CallbackWorker.sidekiq_options(options)
      end

      def validate_heartbeat_and_threshold
        return unless @heartbeat_interval && @orphan_threshold

        return unless @heartbeat_interval >= @orphan_threshold

        raise ArgumentError.new("heartbeat_interval (#{@heartbeat_interval}) must be less than orphan_threshold (#{@orphan_threshold})")
      end
    end
  end
end
