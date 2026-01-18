# frozen_string_literal: true

module Sidekiq
  module AsyncHttp
    # Error object representing an exception from an HTTP request. Note that this
    # is not for HTTP error responses (4xx/5xx), but for actual exceptions raised
    # during the request (timeouts, connection errors, SSL errors, etc).
    class Error
      # Valid error types
      ERROR_TYPES = %i[timeout connection ssl protocol response_too_large unknown].freeze

      # @return [String] Name of the exception class
      attr_reader :class_name

      # @return [String] Exception message
      attr_reader :message

      # @return [Array<String>] Exception backtrace
      attr_reader :backtrace

      # @return [Symbol] Categorized error type
      attr_reader :error_type

      # @return [Float] Request duration in seconds
      attr_reader :duration

      # @return [String] Unique request identifier
      attr_reader :request_id

      # @return [String] Request URL
      attr_reader :url

      # @return [Symbol] HTTP method
      attr_reader :method

      class << self
        # Reconstruct an Error from a hash
        # @param hash [Hash] hash representation
        # @return [Error] reconstructed error
        def from_h(hash)
          new(
            class_name: hash["class_name"],
            message: hash["message"],
            backtrace: hash["backtrace"],
            request_id: hash["request_id"],
            error_type: hash["error_type"]&.to_sym,
            duration: hash["duration"],
            url: hash["url"],
            method: hash["method"]
          )
        end
      end
      class << self
        # Create an Error from an exception using pattern matching
        #
        # @param exception [Exception] the exception to convert
        # @param request_id [String] the request ID
        # @return [Error] the error object
        def from_exception(exception, duration:, request_id:, url:, method:)
          error_type = case exception
          in Async::TimeoutError
            :timeout
          in OpenSSL::SSL::SSLError
            :ssl
          in Errno::ECONNREFUSED | Errno::ECONNRESET | Errno::EHOSTUNREACH
            :connection
          else
            # Check for specific error types by class name
            if exception.is_a?(Sidekiq::AsyncHttp::ResponseTooLargeError)
              :response_too_large
            elsif exception.class.name&.include?("Protocol::Error")
              :protocol
            else
              :unknown
            end
          end

          new(
            class_name: exception.class.name,
            message: exception.message,
            backtrace: exception.backtrace || [],
            request_id: request_id,
            error_type: error_type,
            duration: duration,
            url: url,
            method: method
          )
        end
      end

      # Initializes a new Error.
      #
      # @param class_name [String] Name of the exception class
      # @param message [String] Exception message
      # @param backtrace [Array<String>] Exception backtrace
      # @param error_type [Symbol] Categorized error type
      # @param duration [Float] Request duration in seconds
      # @param request_id [String] Unique request identifier
      # @param url [String] Request URL
      # @param method [Symbol, String] HTTP method
      def initialize(class_name:, message:, backtrace:, error_type:, duration:, request_id:, url:, method:)
        @class_name = class_name
        @message = message
        @backtrace = backtrace
        @error_type = error_type
        @duration = duration
        @request_id = request_id
        @url = url
        @method = method&.to_sym
      end

      # Convert to hash with string keys for serialization
      # @return [Hash] hash representation
      def to_h
        {
          "class_name" => class_name,
          "message" => message,
          "backtrace" => backtrace,
          "request_id" => request_id,
          "error_type" => error_type.to_s,
          "duration" => duration,
          "url" => url,
          "method" => method.to_s
        }
      end

      # Get the actual Exception class constant from the class_name
      # @return [Class, nil] the exception class or nil if not found
      def error_class
        ClassHelper.resolve_class_name(class_name)
      end
    end
  end
end
