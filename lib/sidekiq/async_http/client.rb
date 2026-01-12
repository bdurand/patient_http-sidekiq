# frozen_string_literal: true

module Sidekiq::AsyncHttp
  # Build an HTTP request for asynchronous execution.
  #
  # Usage:
  #   client = Sidekiq::AsyncHttp::Client.new(base_url: "https://api.example.com")
  #   request = client.async_get("/users")
  #   request.execute(sidekiq_job: job_hash, completion_worker: "CompletionWorker", error_worker: "ErrorWorker")
  #
  # The Client handles building HTTP requests with proper URL joining, header merging,
  # and parameter encoding. Call execute() on the returned Request to execute it asynchronously.
  class Client
    attr_accessor :base_url, :headers, :timeout, :connect_timeout, :read_timeout, :write_timeout

    def initialize(base_url: nil, headers: {}, timeout: 30, connect_timeout: nil, read_timeout: nil, write_timeout: nil)
      @base_url = base_url
      @headers = HttpHeaders.new(headers)
      @timeout = timeout
      @connect_timeout = connect_timeout
      @read_timeout = read_timeout
      @write_timeout = write_timeout
    end

    # Build an async HTTP request. Returns a Request. The Request object that must have
    # `execute` called on it to enqueue it for processing.
    # @param method [Symbol] HTTP method (:get, :post, :put, :patch, :delete)
    # @param uri [String, URI] URI path to request (joined with base_url if relative)
    # @param body [String, nil] request body
    # @param json [Object, nil] JSON object to serialize (cannot use with body)
    # @param headers [Hash] additional headers to merge with client headers
    # @param params [Hash] query parameters to add to URL
    # @return [Request] request object
    def async_request(method, uri, body: nil, json: nil, headers: {}, params: {}, timeout: nil, connect_timeout: nil, read_timeout: nil, write_timeout: nil)
      full_uri = @base_url ? URI.join(@base_url, uri.to_s) : URI(uri)
      if params.any?
        query_string = URI.encode_www_form(params)
        full_uri.query = [full_uri.query, query_string].compact.join("&")
      end

      # Merge headers
      merged_headers = headers.any? ? @headers.merge(headers) : @headers

      # Handle JSON body
      request_body = body
      if json
        raise ArgumentError, "Cannot provide both body and json" if body

        request_body = JSON.generate(json)
        merged_headers = merged_headers.merge({"Content-Type" => "application/json; encoding=utf-8"})
      end

      # Create request with all parameters
      Request.new(
        method: method,
        url: full_uri.to_s,
        headers: merged_headers.to_h,
        body: request_body,
        timeout: timeout || @timeout,
        connect_timeout: connect_timeout || @connect_timeout,
        read_timeout: read_timeout || @read_timeout,
        write_timeout: write_timeout || @write_timeout
      )
    end

    def async_get(uri, **kwargs)
      async_request(:get, uri, **kwargs)
    end

    def async_post(uri, **kwargs)
      async_request(:post, uri, **kwargs)
    end

    def async_put(uri, **kwargs)
      async_request(:put, uri, **kwargs)
    end

    def async_patch(uri, **kwargs)
      async_request(:patch, uri, **kwargs)
    end

    def async_delete(uri, **kwargs)
      async_request(:delete, uri, **kwargs)
    end
  end
end
