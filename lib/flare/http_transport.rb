# frozen_string_literal: true

require "net/http"
require "uri"

module Flare
  # Tiny HTTP wrapper used by TraceExporter (and anything else that wants
  # to PUT/POST without pulling in a heavy client). Designed for injection
  # at the boundary so tests can swap in a recording fake; no other moving
  # parts.
  class HttpTransport
    DEFAULT_OPEN_TIMEOUT  = 2
    DEFAULT_READ_TIMEOUT  = 5
    DEFAULT_WRITE_TIMEOUT = 5

    Response = Struct.new(:code, :body, keyword_init: true)

    def initialize(open_timeout: DEFAULT_OPEN_TIMEOUT,
                   read_timeout: DEFAULT_READ_TIMEOUT,
                   write_timeout: DEFAULT_WRITE_TIMEOUT)
      @open_timeout  = open_timeout
      @read_timeout  = read_timeout
      @write_timeout = write_timeout
    end

    def put(url, body, headers = {})
      request(url, body, headers, Net::HTTP::Put)
    end

    def post(url, body, headers = {})
      request(url, body, headers, Net::HTTP::Post)
    end

    private

    def request(url, body, headers, klass)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl     = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @write_timeout if http.respond_to?(:write_timeout=)

      req = klass.new(uri.request_uri == "" ? "/" : uri.request_uri)
      headers.each { |k, v| req[k] = v }
      req.body = body

      response = http.request(req)
      Response.new(code: response.code.to_s, body: response.body)
    end
  end
end
