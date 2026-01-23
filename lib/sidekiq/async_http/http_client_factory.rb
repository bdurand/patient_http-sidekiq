# frozen_string_literal: true

require "async/http"
require "protocol/http/accept_encoding"

module Sidekiq
  module AsyncHttp
    # Factory for creating configured Async::HTTP::Client instances.
    #
    # Encapsulates the logic for building HTTP clients with proper endpoint
    # configuration, timeouts, and middleware wrapping.
    class HttpClientFactory
      # @return [Configuration] the configuration object
      attr_reader :config

      # Initialize the factory.
      #
      # @param config [Configuration] the configuration object
      def initialize(config)
        @config = config
      end

      # Create an HTTP client for the given request.
      #
      # @param request [Request] the request object
      # @return [Protocol::HTTP::AcceptEncoding] the wrapped HTTP client
      def build(request)
        endpoint = create_endpoint(request)
        client = create_client(endpoint)
        wrap_client(client)
      end

      private

      # Create an endpoint for the request.
      #
      # @param request [Request] the request object
      # @return [Async::HTTP::Endpoint] the endpoint
      def create_endpoint(request)
        Async::HTTP::Endpoint.parse(
          request.url,
          connect_timeout: request.connect_timeout,
          idle_timeout: @config.idle_connection_timeout
        )
      end

      # Create an HTTP client for the given endpoint.
      #
      # @param endpoint [Async::HTTP::Endpoint] the endpoint
      # @return [Async::HTTP::Client] the HTTP client
      def create_client(endpoint)
        Async::HTTP::Client.new(endpoint)
      end

      # Wrap the client with middleware (e.g., accept encoding).
      #
      # @param client [Async::HTTP::Client] the client
      # @return [Protocol::HTTP::AcceptEncoding] the wrapped client
      def wrap_client(client)
        Protocol::HTTP::AcceptEncoding.new(client)
      end
    end
  end
end
