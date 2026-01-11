# frozen_string_literal: true

require "webrick"
require "socket"
require "stringio"

# Wrapper for WEBrick::HTTPRequest to provide a consistent interface
class TestRequest
  def initialize(webrick_request)
    @request = webrick_request
  end

  def method
    @request.request_method
  end

  def path
    @request.path
  end

  def headers
    # Convert WEBrick headers to a simple hash with lowercase keys
    @headers ||= begin
      h = {}
      @request.header.each do |key, values|
        # WEBrick headers are arrays, take the first value and lowercase the key
        h[key.downcase] = values.first if values.any?
      end
      h
    end
  end

  def body
    # Return a StringIO wrapper around the body string so .read works
    begin
      body_str = @request.body || ""
    rescue WEBrick::HTTPStatus::BadRequest => e
      # If WEBrick can't read the body (e.g., invalid Content-Length), return empty
      puts "Warning: Failed to read request body: #{e.message}"
      body_str = ""
    end
    StringIO.new(body_str)
  end
end

# Test HTTP server helper for integration tests using WEBrick
#
# Usage:
#   with_test_server do |server|
#     server.on_request { |request| {status: 200, body: "OK"} }
#     # server is now running, make requests to server.url
#   end
class TestServer
  attr_reader :host, :port

  def initialize(host: "127.0.0.1", port: nil)
    @host = host
    @port = port || find_available_port
    @request_handler = nil
    @server = nil
    @thread = nil
  end

  # Configure the request handler
  # The block receives a WEBrick::HTTPRequest and should return a hash with:
  #   - status: Integer (required)
  #   - body: String (optional)
  #   - headers: Hash (optional)
  def on_request(&block)
    @request_handler = block
  end

  # Get the base URL for the server
  def url
    "http://#{@host}:#{@port}"
  end

  # Start the server
  def start
    raise "No request handler configured" unless @request_handler

    @server = WEBrick::HTTPServer.new(
      Port: @port,
      BindAddress: @host,
      Logger: WEBrick::Log.new("/dev/null"),
      AccessLog: []
    )

    # Mount a single handler for all requests
    @server.mount_proc "/" do |req, res|
      if req.path == "/_health"
        res.status = 200
        res.body = "OK"
      else
        handle_request(req, res)
      end
    end

    @thread = Thread.new { @server.start }

    # Poll health check endpoint until server is ready
    require "net/http"
    20.times do |i|
      begin
        response = Net::HTTP.get_response(URI("#{url}/_health"))
        return if response.code == "200"
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError => e
        sleep 0.05
      end
    end

    raise "Server failed to become ready"
  end

  # Stop the server
  def stop
    @server&.shutdown
    @thread&.join(1)
  end

  private

  def find_available_port
    server = TCPServer.new(@host, 0)
    port = server.addr[1]
    server.close
    port
  end

  def handle_request(req, res)
    wrapped_request = TestRequest.new(req)
    response_config = @request_handler.call(wrapped_request)

    res.status = response_config[:status] || 200
    response_config[:headers]&.each { |k, v| res[k] = v }
    res.body = response_config[:body] || ""
  rescue => e
    puts "Error in request handler: #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
    res.status = 500
    res.body = "Internal Server Error: #{e.message}"
  end
end

# RSpec helper module for easy server management
module TestServerHelpers
  # Start a test server, yield it to the block for configuration,
  # start it, and ensure it's stopped after the block completes
  def with_test_server(**options)
    server = TestServer.new(**options)
    # First yield: configure the server
    yield server
    # Start the server
    server.start
    # Return the server for use in the test
    server
  end

  # Helper to ensure server cleanup - call in after block
  def cleanup_server(server)
    server&.stop
  end
end

RSpec.configure do |config|
  config.include TestServerHelpers
end
