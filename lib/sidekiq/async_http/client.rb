# frozen_string_literal: true

module Sidekiq::AsyncHttp
  # The Client is used to build HTTP requests with shared configuration for asynchronous execution.
  #
  # Use Client when you need to make multiple requests to the same API with shared
  # configuration (base URL, headers, timeout).
  #
  # @example Basic usage
  #   client = Sidekiq::AsyncHttp::Client.new(
  #     base_url: "https://api.example.com",
  #     headers: {"Authorization" => "Bearer token"},
  #     timeout: 60
  #   )
  #   request = client.async_get("/users/123")
  #   request.async_execute(callback: MyCallback, callback_args: {user_id: 123})
  #
  # @example The callback service
  #   class MyCallback
  #     def on_complete(response)
  #       User.find(response.callback_args[:user_id]).update!(data: response.json)
  #     end
  #
  #     def on_error(error)
  #       Rails.logger.error("Request failed: #{error.message}")
  #     end
  #   end
  #
  # The Client handles building HTTP requests with proper URL joining, header merging,
  # and parameter encoding. Call +async_execute+ on the returned Request to enqueue it.
  class Client
    # @return [String, URI::HTTP, nil] Base URL for relative URIs
    attr_accessor :base_url

    # @return [HttpHeaders] Default headers for all requests
    attr_accessor :headers

    # @return [Float] Default request timeout in seconds
    attr_accessor :timeout

    # Initializes a new Client.
    #
    # @param base_url [String, URI::HTTP, nil] Base URL for relative URIs
    # @param headers [Hash] Default headers for all requests
    # @param timeout [Float] Default request timeout in seconds
    def initialize(base_url: nil, headers: {}, timeout: 30)
      @base_url = base_url
      @headers = HttpHeaders.new(headers)
      @timeout = timeout
    end

    # Build an async HTTP request. Returns a Request object.
    #
    # Call +async_execute+ on the returned Request to enqueue it for processing.
    # @param method [Symbol] HTTP method (:get, :post, :put, :patch, :delete)
    # @param uri [String, URI::HTTP] URI path to request (joined with base_url if relative)
    # @param body [String, nil] request body
    # @param json [Object, nil] JSON object to serialize (cannot use with body)
    # @param headers [Hash] additional headers to merge with client headers
    # @param params [Hash] query parameters to add to URL
    # @return [Request] request object
    def async_request(method, uri, body: nil, json: nil, headers: {}, params: {}, timeout: nil)
      full_uri = @base_url ? URI.join(@base_url, uri.to_s) : URI(uri)
      if params.any?
        query_string = URI.encode_www_form(params)
        full_uri.query = [full_uri.query, query_string].compact.join("&")
      end

      # Merge headers
      merged_headers = headers&.any? ? @headers.merge(headers) : @headers

      # Handle JSON body
      request_body = body
      if json
        raise ArgumentError.new("Cannot provide both body and json") if body

        request_body = JSON.generate(json)
        merged_headers = merged_headers.merge({"Content-Type" => "application/json; encoding=utf-8"})
      end

      # Create request with all parameters
      Request.new(
        method,
        full_uri.to_s,
        headers: merged_headers.to_h,
        body: request_body,
        timeout: timeout || @timeout
      )
    end

    # Convenience method for GET requests.
    #
    # @param uri [String, URI::HTTP] URI path to request
    # @param kwargs [Hash] additional options (see #async_request)
    # @return [Request] request object
    def async_get(uri, **kwargs)
      async_request(:get, uri, **kwargs)
    end

    # Convenience method for POST requests.
    #
    # @param uri [String, URI::HTTP] URI path to request
    # @param kwargs [Hash] additional options (see #async_request)
    # @return [Request] request object
    def async_post(uri, **kwargs)
      async_request(:post, uri, **kwargs)
    end

    # Convenience method for PUT requests.
    #
    # @param uri [String, URI::HTTP] URI path to request
    # @param kwargs [Hash] additional options (see #async_request)
    # @return [Request] request object
    def async_put(uri, **kwargs)
      async_request(:put, uri, **kwargs)
    end

    # Convenience method for PATCH requests.
    #
    # @param uri [String, URI::HTTP] URI path to request
    # @param kwargs [Hash] additional options (see #async_request)
    # @return [Request] request object
    def async_patch(uri, **kwargs)
      async_request(:patch, uri, **kwargs)
    end

    # Convenience method for DELETE requests.
    #
    # @param uri [String, URI::HTTP] URI path to request
    # @param kwargs [Hash] additional options (see #async_request)
    # @return [Request] request object
    def async_delete(uri, **kwargs)
      async_request(:delete, uri, **kwargs)
    end
  end
end
