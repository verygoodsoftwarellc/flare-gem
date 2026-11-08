# frozen_string_literal: true

require_relative "test_helper"
require "flare/source_location"
require "rails"
require "minitest/mock"

class SourceLocationRootTest < Minitest::Test
  def test_app_parent_directories_do_not_hide_its_source
    %w[ruby bin gems opentelemetry].each do |parent|
      root = "/home/#{parent}/shop"
      Rails.stub(:root, root) do
        attrs = eval("Flare::SourceLocation.add_to_attributes({})", binding, "#{root}/app/models/post.rb", 42)
        assert_equal "app/models/post.rb", attrs["code.filepath"], parent
        assert_equal 42, attrs["code.lineno"]
      end
    end
  end

  def test_gem_and_external_framework_frames_still_do_not_count
    Rails.stub(:root, "/home/ruby/shop") do
      refute Flare::SourceLocation.app_code?("/usr/lib/ruby/gems/3.4.0/gems/framework/app/models/post.rb:1")
      refute Flare::SourceLocation.app_code?("#{Flare::SourceLocation::GEM_ROOT}app/controllers/flare/requests_controller.rb:1")
      refute Flare::SourceLocation.app_code?("/home/ruby/shopper/app/models/post.rb:1")
    end
  end
end
