# frozen_string_literal: true

require "delegate"

module PatientHttp
  module Sidekiq
    # Configuration for the Sidekiq integration.
    #
    # Wraps PatientHttp::Configuration with Sidekiq-aware defaults and adds
    # Sidekiq-specific options like worker queue/retry settings.
    #
    # Access the underlying pool configuration via the +http_pool+ attribute.
    class Configuration < PatientHttp::Configuration
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

      # @return [Boolean] Whether requests execute directly on a processor running in the
      #   current process instead of being enqueued through Sidekiq
      attr_reader :direct_execution

      # @return [Boolean] Whether the URL, HTTP method, and processor of each in-flight
      #   request are recorded so the Web UI can list them
      attr_reader :inflight_details

      # @return [Integer, nil] Size of the gem's dedicated Redis pool; nil sizes it
      #   automatically from completion_threads
      attr_reader :redis_pool_size

      # @return [Numeric] Checkout timeout in seconds for the gem's dedicated Redis pool
      attr_reader :redis_pool_timeout

      # @return [Numeric] Seconds between flushes of locally aggregated stats to Redis
      #   (0 flushes synchronously on every recorded event)
      attr_reader :stats_flush_interval

      # @return [#call, nil] Handler invoked when a CallbackWorker job exhausts all retries.
      # @overload on_retries_exhausted
      #   Returns the current handler.
      #   @return [#call, nil]
      # @overload on_retries_exhausted(&block)
      #   Sets a block as the handler.
      #   @yield [error] block to execute when retries are exhausted
      #   @yieldparam error [PatientHttp::Error] information about the error
      def on_retries_exhausted(&block)
        if block
          @on_retries_exhausted = block
        else
          @on_retries_exhausted
        end
      end

      # @return [Array<PatientHttp::ProcessorObserver>] Registered processor observers
      #   Observers will be registered with the processor when it is started, allowing them to
      #   receive lifecycle callbacks for PatientHttp requests.
      attr_reader :observers

      # Initializes a new Configuration with the specified options.
      #
      # @param heartbeat_interval [Integer] Interval for updating inflight request heartbeats in seconds
      # @param orphan_threshold [Integer] Age threshold for detecting orphaned requests in seconds
      # @param sidekiq_options [Hash, nil] Sidekiq options to apply to RequestWorker and CallbackWorker
      # @param on_retries_exhausted [#call, nil] Handler called when a CallbackWorker job exhausts retries
      # @param direct_execution [Boolean] Whether requests execute directly on a processor
      #   running in the current process instead of being enqueued through Sidekiq
      # @param pool_options [Hash] Options passed through to PatientHttp::Configuration.
      #   Sidekiq-aware defaults are applied for shutdown_timeout and logger
      #   if not explicitly provided.
      def initialize(
        heartbeat_interval: 60,
        orphan_threshold: 300,
        sidekiq_options: nil,
        payload_store_threshold: DEFAULT_PAYLOAD_STORE_THRESHOLD,
        on_retries_exhausted: nil,
        direct_execution: true,
        redis_pool_size: nil,
        redis_pool_timeout: 5,
        stats_flush_interval: 5,
        inflight_details: true,
        **pool_options
      )
        pool_options[:shutdown_timeout] ||= (::Sidekiq.default_configuration[:timeout] || 25) - 2
        pool_options[:logger] ||= ::Sidekiq.logger

        super(**pool_options)

        @observers = []
        @processor_profiles = {default: {}}
        self.sidekiq_options = sidekiq_options
        self.heartbeat_interval = heartbeat_interval
        self.orphan_threshold = orphan_threshold
        self.payload_store_threshold = payload_store_threshold || DEFAULT_PAYLOAD_STORE_THRESHOLD
        self.on_retries_exhausted = on_retries_exhausted
        self.direct_execution = direct_execution
        self.redis_pool_size = redis_pool_size
        self.redis_pool_timeout = redis_pool_timeout
        self.stats_flush_interval = stats_flush_interval
        self.inflight_details = inflight_details
      end

      # Set the on_retries_exhausted handler.
      #
      # This handler is called when a CallbackWorker job exhausts all retries.
      # It receives the same arguments as the on_error callback.
      #
      # @param value [#call, nil] A callable object or nil to clear the handler
      # @raise [ArgumentError] If value is not callable and not nil
      def on_retries_exhausted=(value)
        if value && !value.respond_to?(:call)
          raise ArgumentError.new("on_retries_exhausted must respond to #call, got: #{value.class}")
        end

        @on_retries_exhausted = value
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

      # Set the heartbeat interval for crash recovery.
      #
      # @param value [Numeric] interval in seconds (must be positive)
      # @raise [ArgumentError] if value is not positive or not less than orphan_threshold
      def heartbeat_interval=(value)
        raise ArgumentError.new("heartbeat_interval must be positive, got: #{value.inspect}") unless value.positive?

        @heartbeat_interval = value
        validate_heartbeat_and_threshold
      end

      # Set the orphan detection threshold for crash recovery.
      #
      # @param value [Numeric] threshold in seconds (must be positive and greater than heartbeat_interval)
      # @raise [ArgumentError] if value is not positive or not greater than heartbeat_interval
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

      # Set whether requests execute directly on a processor running in the current
      # process. When enabled, requests made in a process with a running processor
      # skip the Sidekiq queue and go straight to the processor. The value is
      # coerced to a boolean.
      #
      # @param value [Boolean] true to enable direct execution
      # @return [void]
      def direct_execution=(value)
        @direct_execution = !!value
      end

      # Check if direct execution is enabled.
      #
      # @return [Boolean]
      def direct_execution?
        @direct_execution
      end

      # Set the size of the gem's dedicated Redis pool.
      #
      # @param value [Integer, nil] pool size; nil sizes the pool automatically
      # @return [void]
      def redis_pool_size=(value)
        if value.nil?
          @redis_pool_size = nil
          return
        end

        validate_positive_integer(:redis_pool_size, value)
        @redis_pool_size = value
      end

      # Set the checkout timeout for the gem's dedicated Redis pool.
      #
      # @param value [Numeric] timeout in seconds
      # @return [void]
      def redis_pool_timeout=(value)
        unless value.is_a?(Numeric) && value.positive?
          raise ArgumentError.new("redis_pool_timeout must be a positive number, got: #{value.inspect}")
        end

        @redis_pool_timeout = value
      end

      # Set the flush interval for locally aggregated stats.
      #
      # @param value [Numeric] seconds between flushes; 0 flushes synchronously on
      #   every recorded event
      # @return [void]
      def stats_flush_interval=(value)
        unless value.is_a?(Numeric) && value >= 0
          raise ArgumentError.new("stats_flush_interval must be a non-negative number, got: #{value.inspect}")
        end

        @stats_flush_interval = value
      end

      # Set whether the details of each in-flight request are recorded.
      #
      # The URL (see +inflight_url_sanitizer+), HTTP method, and processor name are
      # written next to the crash-recovery record so the Web UI can list the requests
      # that are in flight. Turn this off to keep URLs out of Redis entirely.
      #
      # @param value [Boolean] true to record the details
      # @return [void]
      def inflight_details=(value)
        @inflight_details = !!value
      end

      # Check if in-flight request details are recorded.
      #
      # @return [Boolean]
      def inflight_details?
        @inflight_details
      end

      # Set the sanitizer applied to a request URL before it is recorded for the
      # Web UI, or read the current one.
      #
      # The sanitizer receives the full URL and returns what to display. Without
      # one, the user name, password, query string, and fragment are removed and
      # the scheme, host, and path are kept. Use it to redact more, such as an
      # identifier in the path.
      #
      # @example
      #   config.inflight_url_sanitizer { |url| url.sub(%r{/users/\d+}, "/users/:id") }
      #
      # @overload inflight_url_sanitizer
      #   @return [#call, nil] the current sanitizer
      # @overload inflight_url_sanitizer(&block)
      #   @yield [url] block that returns the URL to display
      #   @yieldparam url [String] the full request URL
      def inflight_url_sanitizer(&block)
        if block
          @inflight_url_sanitizer = block
        else
          @inflight_url_sanitizer
        end
      end

      # Set the sanitizer applied to a request URL before it is recorded.
      #
      # @param value [#call, nil] a callable object, or nil to use the default
      # @raise [ArgumentError] If value is not callable and not nil
      def inflight_url_sanitizer=(value)
        if value && !value.respond_to?(:call)
          raise ArgumentError.new("inflight_url_sanitizer must respond to #call, got: #{value.class}")
        end

        @inflight_url_sanitizer = value
      end

      # Declare a named processor profile, or read one back.
      #
      # Each profile becomes an independent processor with its own capacity,
      # timeouts, and threads. Options are overrides applied on top of this
      # configuration's HTTP pool options. Requests select a processor with the
      # +processor:+ option on +PatientHttp::Sidekiq.execute+ (or on the
      # request itself). The +:default+ profile always exists; declaring it
      # overrides options for the default processor.
      #
      # @example
      #   PatientHttp::Sidekiq.configure do |config|
      #     config.processor(:llm, max_connections: 200, request_timeout: 120)
      #     config.processor(:webhooks, max_connections: 64, request_timeout: 10)
      #   end
      #
      # @param name [Symbol, String] the processor name
      # @param options [Hash] overrides for PatientHttp::Configuration options
      # @return [Hash] the stored options for the profile
      def processor(name, **options)
        key = normalize_processor_name(name)

        if options.any?
          validate_profile_options!(options)
          @processor_profiles[key] = options
        end

        @processor_profiles[key]
      end

      # All declared processor profiles. Always includes :default.
      #
      # @return [Hash{Symbol => Hash}] profile options by processor name
      def processor_profiles
        @processor_profiles.dup
      end

      # Whether more than one processor profile is declared.
      #
      # @return [Boolean]
      def multiple_processors?
        @processor_profiles.size > 1
      end

      # Build the effective configuration for a named processor. The default
      # profile with no overrides is this configuration itself; other profiles
      # get a view of this configuration with their overrides applied, so they
      # share secrets, preprocessors, payload stores, and encryption.
      #
      # @param name [Symbol, String] the processor name
      # @return [PatientHttp::Configuration] the configuration for the processor
      # @raise [ArgumentError] if the profile is not declared
      def processor_config(name)
        key = normalize_processor_name(name)
        profile = @processor_profiles[key]
        raise ArgumentError.new("Unknown processor profile: #{name.inspect}") unless profile

        return self if profile.empty?

        ProfileConfiguration.new(self, profile)
      end

      # Convert to hash for inspection
      # @return [Hash] hash representation with string keys
      def to_h
        super.merge(
          "payload_store_threshold" => payload_store_threshold,
          "heartbeat_interval" => heartbeat_interval,
          "orphan_threshold" => orphan_threshold,
          "sidekiq_options" => sidekiq_options,
          "direct_execution" => direct_execution,
          "on_retries_exhausted" => on_retries_exhausted ? "defined" : nil,
          "redis_pool_size" => redis_pool_size,
          "redis_pool_timeout" => redis_pool_timeout,
          "stats_flush_interval" => stats_flush_interval,
          "inflight_details" => inflight_details,
          "processor_profiles" => processor_profiles.keys.map(&:to_s)
        )
      end

      # View of a base configuration with a profile's option overrides applied.
      # Everything not overridden (secrets, preprocessors, payload stores,
      # logging) delegates to the base configuration, so all processors share
      # those registries.
      #
      # Overrides are applied through a real PatientHttp::Configuration so that
      # each option's writer performs its own normalization. Readers whose
      # value a writer derives from an overridden option are taken from that
      # configuration as well, so an override cannot be half applied.
      class ProfileConfiguration < SimpleDelegator
        # Readers populated as a side effect of another option's writer.
        DERIVED_READERS = {
          encryption_key: [:encryption, :decryption, :encryptor]
        }.freeze

        def initialize(base_configuration, overrides)
          super(base_configuration)
          normalized = PatientHttp::Configuration.new(**overrides)
          readers = overrides.keys.flat_map { |key| [key.to_sym, *DERIVED_READERS[key.to_sym]] }.uniq
          readers.each do |reader|
            next unless normalized.respond_to?(reader)

            define_singleton_method(reader) do |*args, &block|
              normalized.public_send(reader, *args, &block)
            end
          end
        end
      end

      private

      # Profile options must be valid PatientHttp::Configuration options. A
      # throwaway configuration exercises each option's own validation.
      def validate_profile_options!(options)
        PatientHttp::Configuration.new(**options)
      rescue ArgumentError => e
        raise ArgumentError.new("Invalid processor profile options: #{e.message}")
      end

      def normalize_processor_name(name)
        key = name.to_s
        raise ArgumentError.new("processor name cannot be empty") if key.empty?

        key.to_sym
      end

      def apply_sidekiq_options(options)
        PatientHttp::Sidekiq::RequestWorker.sidekiq_options(options)
        PatientHttp::Sidekiq::CallbackWorker.sidekiq_options(options)
      end

      def validate_heartbeat_and_threshold
        return unless @heartbeat_interval && @orphan_threshold

        return unless @heartbeat_interval >= @orphan_threshold

        raise ArgumentError.new("heartbeat_interval (#{@heartbeat_interval}) must be less than orphan_threshold (#{@orphan_threshold})")
      end
    end
  end
end
