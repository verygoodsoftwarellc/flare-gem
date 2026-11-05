# frozen_string_literal: true

require_relative "test_helper"
require "socket"
require "flare/http_transport"

class HttpTransportTest < Minitest::Test
  def setup
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @clients = Queue.new
    @request_lines = Queue.new
    @accept_thread = Thread.new do
      loop do
        client = @server.accept
        @clients << client
        @request_lines << client.gets # read the request line, never answer
      end
    rescue IOError, Errno::EBADF
      nil
    end
    @transport = Flare::HttpTransport.new(open_timeout: 1, read_timeout: 0.2, write_timeout: 1)
  end

  def teardown
    @server.close
    @accept_thread.join(1)
    @clients.size.times { @clients.pop.close }
  end

  def test_get_sends_one_request_when_the_server_does_not_answer
    assert_raises(Net::ReadTimeout) { @transport.get(url("/rules")) }

    assert_equal 1, requests_after_settling("GET /rules ")
  end

  def test_put_sends_one_request_when_the_server_does_not_answer
    assert_raises(Net::ReadTimeout) { @transport.put(url("/upload"), "body") }

    assert_equal 1, requests_after_settling("PUT /upload ")
  end

  def test_a_timed_out_request_stays_within_its_deadline
    transport = Flare::HttpTransport.new(open_timeout: 1, read_timeout: 5, write_timeout: 1)
    started_at = monotonic_now

    assert_raises(Net::ReadTimeout) { transport.get(url("/rules"), {}, timeout: 0.3) }

    # One attempt takes the 0.3s budget; a resend would take it again.
    assert_operator monotonic_now - started_at, :<, 0.5
  end

  private

  def url(path)
    "http://127.0.0.1:#{@port}#{path}"
  end

  # A resend would arrive right after the first read timeout. Counts only
  # our own requests, since other local processes sometimes probe open ports.
  def requests_after_settling(prefix)
    sleep 0.1
    lines = []
    lines << @request_lines.pop until @request_lines.empty?
    lines.count { |line| line.to_s.start_with?(prefix) }
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
