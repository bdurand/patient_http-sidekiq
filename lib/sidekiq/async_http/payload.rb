# frozen_string_literal: true

require "base64"
require "zlib"

module Sidekiq::AsyncHttp
  # Handles encoding and decoding of HTTP response bodies for storage.
  #
  # This class provides compression and encoding strategies for different content types
  # to optimize storage and transmission of response data.
  class Payload
    # @return [Symbol] the encoding type
    attr_reader :encoding

    # @return [String] the encoded data
    attr_reader :encoded_value

    class << self
      # Reconstructs a Payload from a hash representation.
      #
      # @param hash [Hash, nil] hash with "encoding" and "value" keys
      # @return [Payload, nil] reconstructed payload or nil if hash is invalid
      def load(hash)
        return nil if hash.nil? || hash["value"].nil?

        new(hash["encoding"].to_sym, hash["value"])
      end

      # Encodes a value based on its MIME type.
      #
      # For text-based content types, applies gzip compression if beneficial.
      # For binary content, uses Base64 encoding.
      #
      # @param value [String] the value to encode
      # @param mimetype [String, nil] the MIME type of the content
      # @return [Array<Symbol, String>, nil] [encoding, encoded_value] or nil if value is nil
      def encode(value, mimetype)
        return nil if value.nil?

        if is_text_mimetype?(mimetype) && value.encoding == Encoding::UTF_8
          if value.bytesize < 4096
            [:text, value]
          else
            gzipped = Zlib::Deflate.deflate(value)
            if gzipped.bytesize < value.bytesize
              [:gzipped, Base64.encode64(gzipped).chomp]
            else
              [:text, value]
            end
          end
        else
          [:binary, Base64.encode64(value).chomp]
        end
      end

      # Decodes an encoded value based on its encoding type.
      #
      # @param encoded_value [String] the encoded data
      # @param encoding [Symbol] the encoding type (:text, :binary, :gzipped)
      # @return [String, nil] the decoded value or nil if encoded_value is nil
      def decode(encoded_value, encoding)
        return nil if encoded_value.nil?

        case encoding
        when :text
          encoded_value
        when :binary
          Base64.decode64(encoded_value)
        when :gzipped
          Zlib::Inflate.inflate(Base64.decode64(encoded_value))
        end
      end

      private

      def is_text_mimetype?(mimetype)
        mimetype&.match?(/\Atext\/|application\/(?:json|xml|javascript)/)
      end
    end

    # Initializes a new Payload.
    #
    # @param encoding [Symbol] the encoding type
    # @param encoded_value [String] the encoded data
    def initialize(encoding, encoded_value)
      @encoded_value = encoded_value
      @encoding = encoding
    end

    # Returns the decoded value.
    #
    # @return [String, nil] the decoded data
    def value
      self.class.decode(encoded_value, encoding)
    end

    # Converts to a hash representation for serialization.
    #
    # @return [Hash] hash with "encoding" and "value" keys
    def as_json
      {
        "encoding" => encoding.to_s,
        "value" => encoded_value
      }
    end

    alias_method :dump, :as_json
  end
end
