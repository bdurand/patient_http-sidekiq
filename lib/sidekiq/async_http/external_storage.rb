# frozen_string_literal: true

module Sidekiq
  module AsyncHttp
    # Module for external storage of Request and Response payloads.
    #
    # When included in a class, provides methods to store large payloads
    # externally and serialize only a reference. This keeps Sidekiq job
    # arguments small while supporting large request/response bodies.
    #
    # Including classes must define an +original_as_json+ method that returns
    # the full serialization hash.
    #
    # @example Including in a class
    #   class Response
    #     include ExternalStorage
    #
    #     private
    #
    #     def original_as_json
    #       { "status" => status, "body" => body, ... }
    #     end
    #   end
    module ExternalStorage
      # Key used in serialized JSON to indicate an external storage reference
      REFERENCE_KEY = "$ref"

      def self.included(base)
        base.singleton_class.prepend(ClassMethods)
      end

      module ClassMethods
        # Load an object from a hash, fetching from external storage if needed.
        #
        # If the hash contains a +$ref+ key, the data is fetched from the
        # referenced payload store and deserialized. Otherwise, the hash
        # is deserialized directly.
        #
        # @param hash [Hash] Serialized data or reference
        # @return [Object] The deserialized object
        # @raise [RuntimeError] If the referenced store is not registered
        # @raise [RuntimeError] If the stored data is not found
        def load(hash)
          if hash.is_a?(Hash) && hash.key?(REFERENCE_KEY)
            ref = hash[REFERENCE_KEY]
            store_name = ref["store"].to_sym
            key = ref["key"]

            store = Sidekiq::AsyncHttp.configuration.payload_store(store_name)
            unless store
              raise "Payload store '#{store_name}' not registered"
            end

            data = store.fetch(key)
            unless data
              raise "Stored payload not found: #{store_name}/#{key}"
            end

            instance = super(data)
            instance.instance_variable_set(:@_store_name, store_name)
            instance.instance_variable_set(:@_store_key, key)
            instance
          else
            super(hash)
          end
        end
      end

      # Store the payload externally if configured and size exceeds threshold.
      #
      # Does nothing if:
      # - Already stored
      # - No payload store is configured
      # - Payload size is below threshold
      #
      # @return [self]
      def store
        return self if stored?

        config = Sidekiq::AsyncHttp.configuration
        store = config.payload_store
        return self unless store

        json_data = original_as_json
        json_size = json_data.to_json.bytesize
        return self if json_size < config.payload_store_threshold

        key = store.generate_key
        store.store(key, json_data)
        @_store_name = config.default_payload_store_name
        @_store_key = key
        self
      end

      # Check if this object is stored externally.
      #
      # @return [Boolean]
      def stored?
        !@_store_key.nil?
      end

      # Get the external storage key if stored.
      #
      # @return [String, nil]
      def store_key
        @_store_key
      end

      # Get the external storage store name if stored.
      #
      # @return [Symbol, nil]
      def store_name
        @_store_name
      end

      # Remove the payload from external storage.
      #
      # Idempotent - safe to call multiple times or if not stored.
      #
      # @return [void]
      def unstore
        return unless stored?

        store = Sidekiq::AsyncHttp.configuration.payload_store(@_store_name)
        store&.delete(@_store_key)
        @_store_name = nil
        @_store_key = nil
      end

      # Serialize to JSON hash.
      #
      # If stored externally, returns only a reference. Otherwise returns
      # the full serialization.
      #
      # @return [Hash]
      def as_json
        if stored?
          {
            REFERENCE_KEY => {
              "store" => @_store_name.to_s,
              "key" => @_store_key
            }
          }
        else
          original_as_json
        end
      end

      # Alias dump to as_json for compatibility
      alias_method :dump, :as_json

      private

      # Subclasses must implement this to provide the original serialization.
      #
      # @return [Hash] The full serialization hash
      # @raise [NotImplementedError] If not implemented by including class
      def original_as_json
        raise NotImplementedError,
          "#{self.class.name} must implement #original_as_json"
      end
    end
  end
end
