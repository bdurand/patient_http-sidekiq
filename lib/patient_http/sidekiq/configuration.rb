# frozen_string_literal: true

require "delegate"

module PatientHttp
  module Sidekiq
    # Configuration for the Sidekiq integration.
    #
    # Extends `PatientHttp::Configuration` with Sidekiq defaults and adds options
    # for Sidekiq jobs, crash recovery, direct execution, the Web UI, and named
    # processor profiles.
    class Configuration < PatientHttp::Configuration
      # The default size in bytes above which payloads are stored externally.
      #
      # @deprecated Use {PatientHttp::Configuration::DEFAULT_PAYLOAD_STORE_THRESHOLD}.
      #   The `payload_store_threshold` option is defined on the base
      #   configuration, next to `register_payload_store`.
      DEFAULT_PAYLOAD_STORE_THRESHOLD = PatientHttp::Configuration::DEFAULT_PAYLOAD_STORE_THRESHOLD

      # @return [Numeric] The number of seconds without a heartbeat after which
      #   an in-flight request is considered orphaned and re-enqueued.
      attr_reader :orphan_threshold

      # @return [Numeric] The number of seconds between heartbeat updates for
      #   in-flight requests.
      attr_reader :heartbeat_interval

      # @return [Hash, nil] The Sidekiq options for RequestWorker and
      #   CallbackWorker.
      attr_reader :sidekiq_options

      # @return [Boolean] Whether requests made in a process with a running
      #   processor go straight to the processor instead of through the Sidekiq
      #   queue.
      attr_reader :direct_execution

      # @return [Boolean] Whether the URL, HTTP method, and processor of each
      #   in-flight request are recorded so that the Web UI can list them.
      attr_reader :inflight_details

      # @return [Integer, nil] The size of the gem's dedicated Redis pool. If
      #   `nil`, the size is based on `completion_threads`.
      attr_reader :redis_pool_size

      # @return [Numeric] The checkout timeout in seconds for the gem's
      #   dedicated Redis pool.
      attr_reader :redis_pool_timeout

      # @return [Numeric] The number of seconds between flushes of local stats
      #   to Redis. If `0`, every event is written to Redis immediately.
      attr_reader :stats_flush_interval

      # Returns or sets the handler that runs when a CallbackWorker job uses up
      # all of its retries.
      #
      # @overload on_retries_exhausted
      #   Returns the current handler.
      #   @return [#call, nil] The handler, or `nil` if none is set.
      # @overload on_retries_exhausted(&block)
      #   Sets a block as the handler.
      #   @yield [error] The block to run when a job uses up its retries.
      #   @yieldparam error [PatientHttp::Error] The error from the request.
      def on_retries_exhausted(&block)
        if block
          @on_retries_exhausted = block
        else
          @on_retries_exhausted
        end
      end

      # @return [Array<PatientHttp::ProcessorObserver>] The registered processor
      #   observers. Each processor adds these observers when it starts, so they
      #   receive lifecycle events for every request.
      attr_reader :observers

      # Creates a configuration.
      #
      # @param heartbeat_interval [Numeric] The number of seconds between
      #   heartbeat updates for in-flight requests.
      # @param orphan_threshold [Numeric] The number of seconds without a
      #   heartbeat after which an in-flight request is considered orphaned.
      # @param sidekiq_options [Hash, nil] The Sidekiq options for RequestWorker
      #   and CallbackWorker.
      # @param on_retries_exhausted [#call, nil] The handler that runs when a
      #   CallbackWorker job uses up all of its retries.
      # @param direct_execution [Boolean] Whether requests made in a process with
      #   a running processor go straight to the processor.
      # @param redis_pool_size [Integer, nil] The size of the gem's dedicated
      #   Redis pool. If `nil`, the size is based on `completion_threads`.
      # @param redis_pool_timeout [Numeric] The checkout timeout in seconds for
      #   the gem's dedicated Redis pool.
      # @param stats_flush_interval [Numeric] The number of seconds between
      #   flushes of local stats to Redis.
      # @param inflight_details [Boolean] Whether to record the details of each
      #   in-flight request for the Web UI.
      # @param pool_options [Hash] Options for `PatientHttp::Configuration`. If
      #   `shutdown_timeout` isn't set, it defaults to the Sidekiq shutdown
      #   timeout minus 2 seconds. If `logger` isn't set, it defaults to the
      #   Sidekiq logger.
      # @raise [ArgumentError] If an option isn't valid.
      def initialize(
        heartbeat_interval: 60,
        orphan_threshold: 300,
        sidekiq_options: nil,
        on_retries_exhausted: nil,
        direct_execution: true,
        redis_pool_size: nil,
        redis_pool_timeout: 5,
        stats_flush_interval: 5,
        inflight_details: true,
        **pool_options
      )
        # The Sidekiq defaults for these options are read when the options are
        # used, so settings that Sidekiq gets after this configuration is built
        # still apply.
        pool_options = pool_options.compact

        super(**pool_options)

        @shutdown_timeout_set = pool_options.key?(:shutdown_timeout)
        @logger_set = pool_options.key?(:logger)
        @observers = []
        @processor_profiles = {default: {}}
        @processor_configs = {}
        @processor_configs_mutex = Mutex.new
        self.sidekiq_options = sidekiq_options
        self.heartbeat_interval = heartbeat_interval
        self.orphan_threshold = orphan_threshold
        self.on_retries_exhausted = on_retries_exhausted
        self.direct_execution = direct_execution
        self.redis_pool_size = redis_pool_size
        self.redis_pool_timeout = redis_pool_timeout
        self.stats_flush_interval = stats_flush_interval
        self.inflight_details = inflight_details
      end

      # Sets the handler that runs when a CallbackWorker job uses up all of its
      # retries. The handler receives the same error object as the `on_error`
      # callback.
      #
      # @param value [#call, nil] A callable object, or `nil` to remove the
      #   handler.
      # @return [void]
      # @raise [ArgumentError] If `value` isn't `nil` and doesn't respond to
      #   `call`.
      def on_retries_exhausted=(value)
        if value && !value.respond_to?(:call)
          raise ArgumentError.new("on_retries_exhausted must respond to #call, got: #{value.class}")
        end

        @on_retries_exhausted = value
      end

      # Sets the number of seconds between heartbeat updates for in-flight
      # requests.
      #
      # @param value [Numeric] The interval in seconds. Must be positive and less
      #   than `orphan_threshold`.
      # @return [void]
      # @raise [ArgumentError] If `value` isn't positive or isn't less than
      #   `orphan_threshold`.
      def heartbeat_interval=(value)
        raise ArgumentError.new("heartbeat_interval must be positive, got: #{value.inspect}") unless value.positive?

        @heartbeat_interval = value
        validate_heartbeat_and_threshold
      end

      # Sets the number of seconds without a heartbeat after which an in-flight
      # request is considered orphaned and re-enqueued.
      #
      # @param value [Numeric] The threshold in seconds. Must be positive and
      #   greater than `heartbeat_interval`.
      # @return [void]
      # @raise [ArgumentError] If `value` isn't positive or isn't greater than
      #   `heartbeat_interval`.
      def orphan_threshold=(value)
        raise ArgumentError.new("orphan_threshold must be positive, got: #{value.inspect}") unless value.positive?

        @orphan_threshold = value
        validate_heartbeat_and_threshold
      end

      # Sets the Sidekiq options for RequestWorker and CallbackWorker. To set
      # options for only one of them, call `sidekiq_options` on that worker
      # class.
      #
      # @param options [Hash, nil] The Sidekiq options.
      # @return [void]
      # @raise [ArgumentError] If `options` isn't `nil` or a Hash.
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

      # Sets whether requests made in a process with a running processor go
      # straight to the processor instead of through the Sidekiq queue.
      #
      # @param value [Boolean] `true` to enable direct execution. Other values
      #   are converted to a Boolean.
      # @return [void]
      def direct_execution=(value)
        @direct_execution = !!value
      end

      # Returns whether direct execution is enabled.
      #
      # @return [Boolean] `true` if direct execution is enabled.
      def direct_execution?
        @direct_execution
      end

      # Sets the size of the gem's dedicated Redis pool.
      #
      # @param value [Integer, nil] The pool size. If `nil`, the size is based on
      #   `completion_threads`.
      # @return [void]
      # @raise [ArgumentError] If `value` isn't `nil` or a positive Integer.
      def redis_pool_size=(value)
        if value.nil?
          @redis_pool_size = nil
          return
        end

        validate_positive_integer(:redis_pool_size, value)
        @redis_pool_size = value
      end

      # Sets the checkout timeout for the gem's dedicated Redis pool.
      #
      # @param value [Numeric] The timeout in seconds.
      # @return [void]
      # @raise [ArgumentError] If `value` isn't a positive number.
      def redis_pool_timeout=(value)
        unless value.is_a?(Numeric) && value.positive?
          raise ArgumentError.new("redis_pool_timeout must be a positive number, got: #{value.inspect}")
        end

        @redis_pool_timeout = value
      end

      # Sets the number of seconds between flushes of local stats to Redis.
      #
      # @param value [Numeric] The interval in seconds. If `0`, every event is
      #   written to Redis immediately.
      # @return [void]
      # @raise [ArgumentError] If `value` is negative or isn't a number.
      def stats_flush_interval=(value)
        unless value.is_a?(Numeric) && value >= 0
          raise ArgumentError.new("stats_flush_interval must be a non-negative number, got: #{value.inspect}")
        end

        @stats_flush_interval = value
      end

      # Sets whether the details of each in-flight request are recorded.
      #
      # The URL, HTTP method, and processor name are written next to the
      # crash-recovery record so that the Web UI can list the in-flight
      # requests. The URL is sanitized first; see {#inflight_url_sanitizer}.
      # Turn this option off to keep URLs out of Redis.
      #
      # @param value [Boolean] `true` to record the details. Other values are
      #   converted to a Boolean.
      # @return [void]
      def inflight_details=(value)
        @inflight_details = !!value
      end

      # Returns whether in-flight request details are recorded.
      #
      # @return [Boolean] `true` if the details are recorded.
      def inflight_details?
        @inflight_details
      end

      # Returns or sets the sanitizer that runs on a request URL before the URL
      # is recorded for the Web UI.
      #
      # The sanitizer receives the full URL and returns the URL to display. If no
      # sanitizer is set, the user name, password, query string, and fragment
      # are removed, and the scheme, host, and path are kept. Use a sanitizer to
      # remove more, such as an identifier in the path.
      #
      # @example
      #   config.inflight_url_sanitizer { |url| url.sub(%r{/users/\d+}, "/users/:id") }
      #
      # @overload inflight_url_sanitizer
      #   Returns the current sanitizer.
      #   @return [#call, nil] The sanitizer, or `nil` if none is set.
      # @overload inflight_url_sanitizer(&block)
      #   Sets a block as the sanitizer.
      #   @yield [url] The block that returns the URL to display.
      #   @yieldparam url [String] The full request URL.
      def inflight_url_sanitizer(&block)
        if block
          @inflight_url_sanitizer = block
        else
          @inflight_url_sanitizer
        end
      end

      # Sets the sanitizer that runs on a request URL before the URL is
      # recorded.
      #
      # @param value [#call, nil] A callable object, or `nil` to use the default
      #   sanitizer.
      # @return [void]
      # @raise [ArgumentError] If `value` isn't `nil` and doesn't respond to
      #   `call`.
      def inflight_url_sanitizer=(value)
        if value && !value.respond_to?(:call)
          raise ArgumentError.new("inflight_url_sanitizer must respond to #call, got: #{value.class}")
        end

        @inflight_url_sanitizer = value
      end

      # Declares a named processor profile.
      #
      # Each profile runs as an independent processor with its own capacity,
      # timeouts, and threads. The options override this configuration's
      # options for that processor. With no options, the profile uses every
      # option from this configuration. Declaring a profile again replaces its
      # options. A request selects a processor with the `processor:` option.
      # The `:default` profile always exists. Declare it to override options
      # for the default processor.
      #
      # @example
      #   PatientHttp.configure do |config|
      #     config.processor(:llm, max_connections: 200, request_timeout: 120)
      #     config.processor(:webhooks, max_connections: 64, request_timeout: 10)
      #     config.processor(:bulk)
      #   end
      #
      # @param name [Symbol, String] The processor name.
      # @param options [Hash] The PatientHttp::Configuration options to
      #   override. `encryption_key` can't be overridden, because all
      #   processors share encryption.
      # @return [Hash] The options for the profile.
      # @raise [ArgumentError] If `name` is empty or an option isn't valid.
      def processor(name, **options)
        key = normalize_processor_name(name)
        validate_profile_options!(options) if options.any?

        @processor_configs_mutex.synchronize do
          @processor_profiles[key] = options
          @processor_configs.delete(key)
        end

        options
      end

      # Returns the options declared for a named processor profile.
      #
      # @param name [Symbol, String] The processor name.
      # @return [Hash, nil] The options for the profile, or `nil` if the
      #   profile isn't declared.
      def processor_options(name)
        key = name.to_s
        return nil if key.empty?

        @processor_profiles[key.to_sym]
      end

      # Returns all declared processor profiles, including `:default`.
      #
      # @return [Hash{Symbol => Hash}] The profile options, keyed by processor
      #   name.
      def processor_profiles
        @processor_profiles.dup
      end

      # Returns whether more than one processor profile is declared.
      #
      # @return [Boolean] `true` if more than one profile is declared.
      def multiple_processors?
        @processor_profiles.size > 1
      end

      # Returns the configuration for a named processor.
      #
      # A profile without overrides uses this configuration. Other profiles use
      # a view of this configuration with their overrides applied, so all
      # processors share secrets, preprocessors, payload stores, and
      # encryption.
      #
      # @param name [Symbol, String] The processor name.
      # @return [PatientHttp::Configuration] The configuration for the processor.
      # @raise [ArgumentError] If the profile isn't declared.
      def processor_config(name)
        key = normalize_processor_name(name)
        profile = @processor_profiles[key]
        raise ArgumentError.new("Unknown processor profile: #{name.inspect}") unless profile

        return self if profile.empty?

        @processor_configs_mutex.synchronize do
          @processor_configs[key] ||= ProfileConfiguration.new(self, profile)
        end
      end

      # Returns the graceful shutdown timeout in seconds. If it isn't set,
      # returns the Sidekiq shutdown timeout minus 2 seconds, so that the
      # processor stops before Sidekiq gives up on the worker.
      #
      # @return [Numeric] The timeout in seconds.
      def shutdown_timeout
        return super if @shutdown_timeout_set

        (::Sidekiq.default_configuration[:timeout] || 25) - 2
      end

      # Sets the graceful shutdown timeout in seconds.
      #
      # @param value [Numeric] The timeout in seconds. Must be positive.
      # @return [void]
      # @raise [ArgumentError] If `value` isn't positive.
      def shutdown_timeout=(value)
        super
        @shutdown_timeout_set = true
      end

      # Returns the logger. If it isn't set, returns the Sidekiq logger.
      #
      # @return [Logger] The logger.
      def logger
        return super if @logger_set

        ::Sidekiq.logger || super
      end

      # Sets the logger.
      #
      # @param value [Logger, nil] The logger.
      # @return [void]
      def logger=(value)
        super
        @logger_set = true
      end

      # Returns the configuration as a Hash for inspection.
      #
      # @return [Hash{String => Object}] The option values, keyed by option
      #   name.
      def to_h
        super.merge(
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

      # A view of a base configuration with a processor profile's overrides
      # applied. Options that the profile doesn't override, such as secrets,
      # preprocessors, payload stores, and the logger, come from the base
      # configuration, so all processors share them.
      #
      # The overrides are applied to a separate PatientHttp::Configuration so
      # that each option's writer normalizes its own value.
      class ProfileConfiguration < SimpleDelegator
        # Creates a view of a configuration with overrides applied.
        #
        # @param base_configuration [Configuration] The configuration that
        #   provides the options that aren't overridden.
        # @param overrides [Hash] The PatientHttp::Configuration options to
        #   override.
        def initialize(base_configuration, overrides)
          super(base_configuration)
          normalized = PatientHttp::Configuration.new(**overrides)
          overrides.each_key do |key|
            reader = key.to_sym
            next unless normalized.respond_to?(reader)

            define_singleton_method(reader) do |*args, &block|
              normalized.public_send(reader, *args, &block)
            end
          end
        end
      end

      private

      # Validates processor profile options. Each option must be a valid
      # PatientHttp::Configuration option other than `encryption_key`. The
      # options are applied to a temporary configuration so that each option's
      # writer validates its own value.
      #
      # @param options [Hash] The profile options.
      # @return [void]
      # @raise [ArgumentError] If an option isn't valid.
      def validate_profile_options!(options)
        if options.key?(:encryption_key)
          raise ArgumentError.new("encryption_key can't be set for a processor profile")
        end

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
