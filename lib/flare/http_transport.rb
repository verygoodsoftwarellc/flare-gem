# frozen_string_literal: true

require "net/http"
require "uri"

require_relative "deadline"

module Flare
  # Tiny HTTP wrapper used by TraceExporter (and anything else that wants
  # to PUT/POST without pulling in a heavy client). Designed for injection
  # at the boundary so tests can swap in a recording fake; no other moving
  # parts.
  class HttpTransport
    DeadlineExceeded = Class.new(StandardError)
    DEFAULT_OPEN_TIMEOUT  = 2
    DEFAULT_READ_TIMEOUT  = 5
    DEFAULT_WRITE_TIMEOUT = 5

    Response = Struct.new(:code, :body, :headers, keyword_init: true) do
      def header(name)
        return nil unless headers
        headers[name] || headers[name.downcase] || headers[name.upcase]
      end
    end

    def initialize(open_timeout: DEFAULT_OPEN_TIMEOUT,
                   read_timeout: DEFAULT_READ_TIMEOUT,
                   write_timeout: DEFAULT_WRITE_TIMEOUT)
      @open_timeout  = open_timeout
      @read_timeout  = read_timeout
      @write_timeout = write_timeout
    end

    def get(url, headers = {}, timeout: nil)
      request(url, nil, headers, Net::HTTP::Get, timeout: timeout)
    end

    def put(url, body, headers = {}, timeout: nil)
      request(url, body, headers, Net::HTTP::Put, timeout: timeout)
    end

    def post(url, body, headers = {}, timeout: nil)
      request(url, body, headers, Net::HTTP::Post, timeout: timeout)
    end

    private

    def request(url, body, headers, klass, timeout: nil)
      deadline = Deadline.new(timeout)
      raise DeadlineExceeded if deadline.expired?

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl     = uri.scheme == "https"
      http.open_timeout = effective_timeout(@open_timeout, deadline.remaining)
      http.read_timeout = effective_timeout(@read_timeout, deadline.remaining)
      http.write_timeout = effective_timeout(@write_timeout, deadline.remaining) if http.respond_to?(:write_timeout=)

      req = klass.new(uri.request_uri == "" ? "/" : uri.request_uri)
      headers.each { |k, v| req[k] = v }
      req.body = body if body

      response = http.request(req)
      raise DeadlineExceeded if deadline.expired?

      hash = response.each_header.to_h
      Response.new(code: response.code.to_s, body: response.body, headers: hash)
    end

    def effective_timeout(configured_timeout, remaining)
      return configured_timeout unless remaining

      [configured_timeout, remaining].min
    end
  end
end
