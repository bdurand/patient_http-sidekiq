# frozen_string_literal: true

require "base64"
require "zlib"

module Sidekiq::AsyncHttp
  class Payload
    attr_reader :mimetype, :encoding, :encoded_value

    class << self
      def from_h(hash)
        return nil if hash.nil? || hash["value"].nil?

        new(hash["encoding"].to_sym, hash["value"])
      end

      def encode(value, mimetype)
        return nil if value.nil?

        if is_text_mimetype?(mimetype)
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

    def initialize(encoding, encoded_value)
      @encoded_value = encoded_value
      @encoding = encoding
    end

    def value
      self.class.decode(encoded_value, encoding)
    end

    def to_h
      {
        "encoding" => encoding.to_s,
        "value" => encoded_value
      }
    end
  end
end
