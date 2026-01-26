# frozen_string_literal: true

module Sidekiq
  module AsyncHttp
    # Reads and validates HTTP response bodies.
    #
    # Encapsulates the logic for reading async HTTP responses with size validation
    # and building Response objects from the raw response data.
    class ResponseReader
      # @return [Configuration] the configuration object
      attr_reader :config

      # Initialize the reader.
      #
      # @param config [Configuration] the configuration object
      def initialize(config)
        @config = config
      end

      # Read the response body with size validation.
      #
      # Reads the async HTTP response body asynchronously to completion, which allows
      # the connection to be reused. The async-http client handles connection pooling
      # and keep-alive internally. Using iteration instead of read() ensures non-blocking
      # I/O that yields to the reactor.
      #
      # @param async_response [Async::HTTP::Protocol::Response] the async HTTP response
      # @param headers_hash [Hash] the response headers
      # @return [String, nil] the response body or nil if no body present
      # @raise [ResponseTooLargeError] if body exceeds max_response_size
      def read_body(async_response, headers_hash)
        return nil unless async_response.body

        validate_content_length(headers_hash)
        body = read_body_chunks(async_response)
        apply_charset_encoding(body, headers_hash)
      end

      private

      # Validate content-length header doesn't exceed max size.
      #
      # @param headers_hash [Hash] the response headers
      # @raise [ResponseTooLargeError] if content-length exceeds max_response_size
      def validate_content_length(headers_hash)
        content_length = headers_hash["content-length"]&.to_i
        if content_length && content_length > @config.max_response_size
          raise ResponseTooLargeError.new(
            "Response body size (#{content_length} bytes) exceeds maximum allowed size (#{@config.max_response_size} bytes)"
          )
        end
      end

      # Read body chunks while checking size.
      #
      # @param async_response [Async::HTTP::Protocol::Response] the async HTTP response
      # @return [String] the response body in ASCII-8BIT encoding
      # @raise [ResponseTooLargeError] if body size exceeds max_response_size during read
      def read_body_chunks(async_response)
        chunks = []
        total_size = 0

        async_response.body.each do |chunk|
          total_size += chunk.bytesize

          if total_size > @config.max_response_size
            raise ResponseTooLargeError.new(
              "Response body size exceeded maximum allowed size (#{@config.max_response_size} bytes)"
            )
          end

          chunks << chunk
        end

        # Join chunks and force to binary encoding to preserve raw bytes
        chunks.join.force_encoding(Encoding::ASCII_8BIT)
      end

      # Extract charset from Content-Type header.
      #
      # @param headers_hash [Hash] the response headers
      # @return [String, nil] the charset name or nil if not specified
      def extract_charset(headers_hash)
        content_type = headers_hash["content-type"]
        return nil unless content_type

        # Match charset parameter in Content-Type header
        # Examples: "text/html; charset=utf-8", "application/json; charset=ISO-8859-1"
        # Also handles quoted values: "text/html; charset="utf-8""
        match = content_type.match(/;\s*charset\s*=\s*([^;\s]+)/i)
        return nil unless match

        charset = match[1].strip
        # Remove surrounding quotes if present
        charset.gsub(/\A["']|["']\z/, "")
      end

      # Apply charset encoding to response body.
      #
      # Sets the string encoding based on the charset specified in the Content-Type header.
      # Falls back to ASCII-8BIT if charset is invalid or not recognized.
      #
      # @param body [String] the response body
      # @param headers_hash [Hash] the response headers
      # @return [String] the body with proper encoding set
      def apply_charset_encoding(body, headers_hash)
        return body unless body

        charset = extract_charset(headers_hash)
        return body unless charset

        begin
          # Try to find the encoding
          encoding = Encoding.find(charset)
          # Force the encoding on the binary string
          body.force_encoding(encoding)
        rescue ArgumentError
          # Invalid or unknown charset, leave as binary
          @config.logger&.warn("[Sidekiq::AsyncHttp] Unknown charset '#{charset}' in Content-Type header")
          body
        end
      end
    end
  end
end
