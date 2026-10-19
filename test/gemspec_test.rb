# frozen_string_literal: true

require "test_helper"

class GemspecTest < Minitest::Test
  def test_links_do_not_point_at_the_old_repo
    spec = Gem::Specification.load(File.expand_path("../flare.gemspec", __dir__))
    links = [spec.homepage, *spec.metadata.values].join(" ")

    refute_match %r{github\.com/jnunemaker/flare\b}, links
    %w[changelog_uri bug_tracker_uri documentation_uri].each do |key|
      assert spec.metadata[key]&.start_with?(spec.metadata["source_code_uri"]), "#{key} should live under source_code_uri"
    end
  end
end
