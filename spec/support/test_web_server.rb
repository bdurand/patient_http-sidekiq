# frozen_string_literal: true

require "puma"
require "json"
require "net/http"
require "uri"

class TestWebServer
  def initialize
    @thread = nil
    @port = nil
    @server = nil
    @ready = false
  end

  def start(port = nil)
    return self if @thread&.alive?

    port = find_free_port if port.nil? || port.zero?
    @port = port
    @thread = Thread.new { run_server }
    self
  end

  def ready?(timeout: 5.0)
    unless @ready
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        if server_ready?
          @ready = true
          break
        end
        sleep 0.01
      end
    end

    @ready
  end

  def stop
    @server&.stop
    @thread&.kill
  end

  def base_url
    "http://localhost:#{@port}"
  end

  private

  def find_free_port
    server = TCPServer.new("localhost", 0)
    port = server.addr[1]
    server.close
    port
  end

  def run_server
    server = Puma::Server.new(build_app, nil, {min_threads: 0, max_threads: 10, log_writer: Puma::LogWriter.null})
    server.add_tcp_listener("localhost", @port)
    @server = server
    server.run
  end

  def build_app
    lambda do |env|
      path = env["PATH_INFO"]

      if path == "/health"
        [200, {"Content-Type" => "text/plain"}, ["OK"]]
      elsif path.match?(%r{\A/test/\d+\z})
        test_response(env)
      elsif (match = path.match(%r{\A/delay/(\d+)\z}))
        delay = match[1].to_f / 1000.0
        sleep(delay)
        delay_response(delay)
      else
        [404, {"Content-Type" => "text/plain"}, ["404 page not found\n"]]
      end
    end
  end

  def health_check_response
    [200, {"Content-Type" => "text/plain"}, ["OK"]]
  end

  def test_response(env)
    path = env["PATH_INFO"]
    query_string = env["QUERY_STRING"] || ""
    headers = extract_headers(env)

    # Ensure request body is fully consumed before sending response
    # This is important for POST/PUT requests with bodies
    body = read_body(env)

    status_code = path.sub(%r{\A/test/}, "").to_i

    response_body = JSON.generate({
      status: status_code,
      body: body,
      headers: headers,
      query_string: query_string
    })

    [
      status_code,
      {
        "Content-Type" => "application/json",
        "Content-Length" => response_body.bytesize.to_s
      },
      [response_body]
    ]
  end

  def delay_response(delay)
    [200, {"Content-Type" => "application/json"}, [JSON.generate({delay: delay})]]
  end

  def extract_headers(env)
    headers = {}

    # Extract HTTP_* headers
    env.each do |key, value|
      if key.start_with?("HTTP_")
        header_name = key.sub(/^HTTP_/, "").downcase.tr("_", "-")
        headers[header_name] = value
      end
    end

    # Rack stores some headers without HTTP_ prefix
    headers["content-type"] = env["CONTENT_TYPE"] if env["CONTENT_TYPE"]
    headers["content-length"] = env["CONTENT_LENGTH"] if env["CONTENT_LENGTH"]

    headers
  end

  def read_body(env)
    input = env["rack.input"]
    return "" unless input

    # Read and return the entire body
    body = input.read

    # Rewind the input stream in case it needs to be read again
    input.rewind if input.respond_to?(:rewind)

    body || ""
  end

  def server_ready?
    uri = URI("#{base_url}/health")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 0.1
    http.read_timeout = 0.1
    response = http.get(uri.path)
    response.is_a?(Net::HTTPSuccess)
  rescue => e
    warn e.inspect
    false
  end
end
