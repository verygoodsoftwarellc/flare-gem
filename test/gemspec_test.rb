# frozen_string_literal: true

require "test_helper"

class GemspecTest < Minitest::Test
  def test_links_do_not_point_at_the_old_repo
    links = [spec.homepage, *spec.metadata.values].join(" ")

    refute_match %r{github\.com/jnunemaker/flare\b}, links
    %w[changelog_uri bug_tracker_uri documentation_uri].each do |key|
      assert spec.metadata[key]&.start_with?(spec.metadata["source_code_uri"]), "#{key} should live under source_code_uri"
    end
  end

  def test_opentelemetry_dependencies_have_floors_and_ceilings
    otel = spec.runtime_dependencies.select { |dep| dep.name.start_with?("opentelemetry-") }

    refute_empty otel
    otel.each do |dep|
      refute dep.requirement.satisfied_by?(Gem::Version.new("0.0.1")), "#{dep.name} needs a floor"
      refute dep.requirement.satisfied_by?(Gem::Version.new("2.0")), "#{dep.name} needs a ceiling"
    end
  end

  private

  def spec
    @spec ||= Gem::Specification.load(File.expand_path("../flare.gemspec", __dir__))
  end
end
