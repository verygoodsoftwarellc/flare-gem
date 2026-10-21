# frozen_string_literal: true

require_relative "test_helper"
require "flare/storage/sqlite"

class StorageTest < Minitest::Test
  def test_sqlite_implements_every_base_method_with_the_same_parameters
    Flare::Storage::Base.public_instance_methods(false).each do |name|
      implementation = Flare::Storage::SQLite.instance_method(name)

      assert_equal Flare::Storage::SQLite, implementation.owner, "SQLite does not implement Base##{name}"
      assert_equal Flare::Storage::Base.instance_method(name).parameters, implementation.parameters, "Base##{name} parameters differ from SQLite"
    end
  end
end
