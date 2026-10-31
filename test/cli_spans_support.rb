# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "sqlite3"
require "time"
require "tmpdir"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "flare/storage"
require "flare/storage/sqlite"

# Runs exe/flare in a subprocess, the way it runs in an app, against a spans
# database laid out like SQLiteExporter writes it.
module CLISpansSupport
  ROOT = File.expand_path("..", __dir__)
  ROOT_PARENT = "0000000000000000"

  private

  def in_app
    Dir.mktmpdir { |dir| yield File.realpath(dir) }
  end

  def flare(dir, *args)
    Open3.capture3(RbConfig.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "exe", "flare"), *args, chdir: dir)
  end

  def create_database(dir, relative = "db/flare.sqlite3")
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    Flare::Storage::SQLite.new(path).send(:setup_database)
    SQLite3::Database.new(path)
  end

  def insert_span(db, trace:, name:, kind:, parent:, ns:, at:, properties:)
    stamp = at.iso8601(6)
    start = (at.to_r * 1_000_000_000).to_i
    db.execute(<<~SQL, [name, kind, "s#{rand(1 << 32)}", trace, parent, start, start + ns, stamp, stamp])
      INSERT INTO flare_spans (name, kind, span_id, trace_id, parent_span_id, start_timestamp, end_timestamp, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    db.last_insert_row_id.tap { |id| insert_properties(db, "Flare::Span", id, properties, stamp) }
  end

  def insert_properties(db, owner_type, owner_id, properties, stamp)
    properties.each do |key, value|
      db.execute("INSERT INTO flare_properties (key, value, value_type, owner_type, owner_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [key, JSON.generate(value), value.is_a?(Integer) ? 1 : 0, owner_type, owner_id, stamp, stamp])
    end
  end
end
