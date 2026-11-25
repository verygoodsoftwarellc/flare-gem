# frozen_string_literal: true

require_relative "test_helper"
require "flare/client_headers"
require "minitest/mock"

# Passes its own Configuration rather than loading lib/flare.rb, which would
# skip the engine for integration tests that require Rails later.
class ClientHeadersTest < Minitest::Test
  def setup
    @configuration = Flare::Configuration.new
    @configuration.revision = nil
  end

  def test_user_agent_matches_server_regex
    ua = headers["User-Agent"]
    assert_equal "Flare Ruby/#{Flare::VERSION}", ua

    # Mirrors the server's SDK_USER_AGENT parser: capture group 1 = version.
    assert_match %r{\A(?:Flare|Caboose) Ruby/(\S+)}, ua
    assert_equal Flare::VERSION, ua[%r{\AFlare Ruby/(\S+)}, 1]
  end

  def test_includes_client_metadata
    assert_equal "ruby", headers["X-Client-Language"]
    assert_equal RUBY_VERSION, headers["X-Client-Language-Version"]
    assert_equal RUBY_PLATFORM, headers["X-Client-Platform"]
    assert_equal Process.pid.to_s, headers["X-Client-Pid"]
    refute_nil headers["X-Client-Hostname"]
  end

  def test_includes_revision_when_one_resolves
    @configuration.revision = "abc123"
    assert_equal "abc123", headers["X-Client-Revision"]
  end

  def test_omits_revision_when_none_resolves
    Flare::Revision.stub(:resolve, nil) do
      refute headers.key?("X-Client-Revision")
    end
  end

  def test_excludes_auth_and_context_headers
    refute headers.key?("Authorization")
    refute headers.key?("Flare-Project")
    refute headers.key?("Flare-Environment")
  end

  private

  def headers
    Flare::ClientHeaders.to_h(@configuration)
  end
end
