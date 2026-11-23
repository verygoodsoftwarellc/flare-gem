# frozen_string_literal: true

require_relative "test_helper"
require "flare/source_location"
require "minitest/mock"

class SourceLocationTest < Minitest::Test
  def test_app_code_with_flare_in_the_path_is_app_code
    assert Flare::SourceLocation.app_code?("/home/deploy/flareapp/app/models/user.rb:3:in 'User.active'")
    assert Flare::SourceLocation.app_code?("/srv/shop/app/controllers/flares_controller.rb:7:in 'FlaresController#index'")
  end

  def test_frames_from_this_gem_are_not_app_code
    gem_frame = "#{File.expand_path("../app/controllers/flare/requests_controller.rb", __dir__)}:5:in 'index'"

    refute Flare::SourceLocation.app_code?(gem_frame)
    refute Flare::SourceLocation.app_code?("/usr/lib/ruby/gems/3.4.0/gems/flare-0.4.2/app/controllers/flare/requests_controller.rb:5")
  end

  def test_add_to_attributes_from_app_code
    attrs = from_app_frame { Flare::SourceLocation.add_to_attributes({}) }

    assert_equal "/srv/shop/app/models/user.rb", attrs["code.filepath"]
    assert_equal 12, attrs["code.lineno"]
    assert_equal "/srv/shop/app/models/user.rb:12", attrs["code.stacktrace"].lines.first.split(" in ").first
  end

  def test_add_to_attributes_reads_the_backtrace_once
    calls = 0
    real_caller = Kernel.instance_method(:caller).bind(Flare::SourceLocation)
    attrs = Flare::SourceLocation.stub(:caller, ->(*args) { calls += 1; real_caller.call(*args) }) do
      from_app_frame { Flare::SourceLocation.add_to_attributes({}) }
    end

    assert attrs["code.filepath"]
    assert_equal 1, calls
  end

  private

  # Runs the block from a frame that looks like app code.
  def from_app_frame(&block)
    eval("block.call", binding, "/srv/shop/app/models/user.rb", 12)
  end
end
