# frozen_string_literal: true

require "test_helper"

class GemspecTest < Minitest::Test
  REPO_URL = "https://github.com/verygoodsoftwarellc/flare-gem"

  def setup
    @spec = Gem::Specification.load(File.expand_path("../flare.gemspec", __dir__))
  end

  def test_links_point_at_the_current_repo
    assert_equal REPO_URL, @spec.homepage
    assert_equal REPO_URL, @spec.metadata["source_code_uri"]
    assert_equal "#{REPO_URL}/releases", @spec.metadata["changelog_uri"]
    assert_equal "#{REPO_URL}/issues", @spec.metadata["bug_tracker_uri"]
    assert_equal "#{REPO_URL}#readme", @spec.metadata["documentation_uri"]
    assert_equal "https://flare.am", @spec.metadata["homepage_uri"]
  end
end
