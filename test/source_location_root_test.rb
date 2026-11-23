# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"

class SourceLocationRootTest < Minitest::Test
  def test_app_parent_directories_do_not_hide_its_source
    %w[ruby bin gems opentelemetry app].each do |parent|
      root = "/home/#{parent}/shop"
      out = run_with_root(root, <<~RUBY)
        attrs = eval("Flare::SourceLocation.add_to_attributes({})", binding, "#{root}/app/models/post.rb", 42)
        puts JSON.generate(attrs)
      RUBY
      attrs = JSON.parse(out)
      assert_equal "app/models/post.rb", attrs["code.filepath"], parent
      assert_equal 42, attrs["code.lineno"]
    end
  end

  def test_gem_and_external_framework_frames_still_do_not_count
    out = run_with_root("/home/ruby/shop", <<~RUBY)
      puts JSON.generate([
        Flare::SourceLocation.app_code?("/usr/lib/ruby/gems/3.4.0/gems/framework/app/models/post.rb:1"),
        Flare::SourceLocation.app_code?("\#{Flare::SourceLocation::GEM_ROOT}app/controllers/flare/requests_controller.rb:1"),
        Flare::SourceLocation.app_code?("/home/ruby/shopper/app/models/post.rb:1")
      ])
    RUBY
    assert_equal [false, false, false], JSON.parse(out)
  end

  private

  def run_with_root(root, code)
    script = <<~RUBY
      require "json"
      require "pathname"
      require "flare/source_location"
      module Rails
        def self.root
          Pathname.new(#{root.inspect})
        end
      end
      #{code}
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
    assert status.success?, err
    out
  end
end
