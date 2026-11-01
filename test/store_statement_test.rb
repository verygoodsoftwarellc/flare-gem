# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/flare/store_statement"

class StoreStatementTest < Minitest::Test
  def redis(text, pipelined: true)
    Flare::StoreStatement.redis(text, pipelined: pipelined)
  end

  def mongo(text)
    Flare::StoreStatement.mongo(text)
  end

  def test_redis_keeps_the_command_and_the_first_key_segment
    assert_equal "SET session:?", redis("SET session:abc:hunter2 hunter2")
    assert_equal "GET users:?", redis("GET users:hunter2")
    assert_equal "GET cachekey/?", redis("GET cachekey/hunter2")
    assert_equal "MGET a:?", redis("MGET a:1 hunter2:2")
    assert_equal "HSET user_data-x:?", redis("HSET user_data-x:hunter2 f v")
  end

  def test_redis_masks_a_key_with_no_separator_or_an_odd_first_segment
    ["GET hunter2", "GET bare", "GET h4nter2:x", "GET {tag}:x", "GET :x", "GET #{"a" * 50}:x"].each do |line|
      assert_equal "GET ?", redis(line), line
    end
  end

  def test_redis_commands_without_a_key_never_keep_arguments
    assert_equal "AUTH ?", redis("AUTH hunter2")
    assert_equal "CONFIG ?", redis("CONFIG SET requirepass hunter2")
    assert_equal "PUBLISH ?", redis("PUBLISH chan:x hunter2")
    assert_equal "PING", redis("PING")
    assert_equal "FT.SEARCH ?", redis("FT.SEARCH idx hunter2")
  end

  def test_redis_script_commands_keep_only_the_command
    assert_equal "EVAL ?", redis("EVAL return redis.call('get',KEYS[1]) 1 session:hunter2 hunter2")
    assert_equal "EVALSHA ?", redis("EVALSHA abc123 1 session:hunter2 hunter2")
  end

  def test_redis_reads_what_the_instrumentation_already_masked
    assert_equal "SET ?", redis("SET ? ?")
    assert_equal "EVAL ?", redis("EVAL ? ? ? ?")
    assert_equal "HELLO ?\nCLIENT ?", redis("HELLO ?\nCLIENT ? ? ?\nCLIENT ? ? ?")
  end

  def test_redis_output_reads_the_same_when_masked_again
    ["SET session:abc x", "GET hunter2", "MULTI\nSET y:1 x\nEXEC", "EVAL x 1 k v", (1..30).map { |i| "GET k#{"x" * (i % 2)}:#{i}\nSET z#{"y" * (i % 3)}:1 v" }.join("\n")].each do |text|
      once = redis(text)
      assert_equal once, redis(once), text
    end
  end

  def test_redis_pipelines_are_readable_and_bounded
    assert_equal "MULTI\nSET ?\nEXEC", redis("MULTI\nSET y:1 hunter2\nEXEC")
    assert_equal "GET ?", redis((1..50).map { |i| "GET users:#{i}" }.join("\n"))
    assert_equal "SET ?\nGET ?", redis("SET a:1 first\nGET secretword:hunter2")
    many = (1..40).map { |i| "#{%w[GET SET INCR DEL TTL HGET HSET LPOP RPOP SADD SREM ZADD][i % 12]} users:#{i}" }.join("\n")
    assert_equal Flare::StoreStatement::MAX_REDIS_LINES + 1, redis(many).lines.size
    assert redis(many).end_with?("\n...")
  end

  def test_redis_lines_that_are_not_commands_are_dropped
    assert_equal "SET ?\nGET ?", redis("SET a:1 first\nhunter2 second\nGET b:1")
    assert_equal "?", redis("hunter2 x\nnot a command")
  end

  def test_redis_single_command_ignores_later_lines_in_its_value
    assert_equal "SET a:?", redis("SET a:1 first\nGET secret:hunter2", pipelined: false)
    assert_equal "?", redis("hunter x", pipelined: false)
  end

  def test_redis_nothing_usable
    ["", nil, "\xFF\xFE", "   "].each { |text| assert_equal "?", redis(text), text.inspect }
  end

  def test_mongo_keeps_structure_and_masks_values
    assert_equal '{"find":"users","filter":{"email":"?"}}', mongo('{"find":"users","filter":{"email":"hunter2"}}')
    assert_equal '{"filter":{"email":"?"}}', mongo('{"filter":{"email":"?"}}')
    assert_equal '{"update":"users","ordered":"?","updates":[{"q":{"email":"?"},"u":{"$set":{"secret":"?"}}}]}',
      mongo('{"update":"users","ordered":true,"updates":[{"q":{"email":"hunter2"},"u":{"$set":{"secret":"hunter2"}}}]}')
  end

  def test_mongo_arrays_reduce_to_unique_masked_values
    assert_equal '{"filter":{"n":{"$in":["?"]}}}', mongo('{"filter":{"n":{"$in":["hunter2","hunter3",3,null,true]}}}')
    assert_equal '{"a":[{"x":"?"},{"y":"?"},"?"]}', mongo('{"a":[{"x":"hunter2"},{"y":"hunter2"},{"x":"hunter3"},"hunter2"]}')
  end

  def test_mongo_masks_dotted_key_tails_and_odd_keys
    assert_equal '{"filter":{"a.?":"?"}}', mongo('{"filter":{"a.b.hunter2":"hunter2"}}')
    assert_equal '{"filter":{"?":"?"}}', mongo('{"filter":{"hunter 2!":"hunter2"}}')
    assert_equal '{"?":"?"}', mongo(%({"#{"a" * 80}":"hunter2"}))
  end

  def test_mongo_keeps_only_a_leading_command_and_its_collection
    assert_equal '{"find":"users"}', mongo('{"find":"users"}')
    assert_equal '{"aggregate":"users","pipeline":[{"$match":{"a":"?"}},{"$limit":"?"}],"cursor":{}}',
      mongo('{"aggregate":"users","pipeline":[{"$match":{"a":"hunter2"}},{"$limit":1}],"cursor":{}}')
    assert_equal '{"filter":"?","find":"?"}', mongo('{"filter":"hunter2","find":"hunter2"}')
    assert_equal '{"find":"?"}', mongo('{"find":"hunter 2"}')
    assert_equal '{"password":"?"}', mongo('{"password":"hunter2"}')
    assert_equal '{"find":{"a":"?"}}', mongo('{"find":{"a":"hunter2"}}')
  end

  def test_mongo_fails_closed_on_anything_else
    ['{"find":"users","filter":{"a":"hunter2"', "not json hunter2", "", nil, '"hunter2"', "[1,2]", "\xFF", '{"a":"hunter2"}...'].each do |text|
      assert_equal "?", mongo(text), text.inspect
    end
  end

  def test_mongo_bounds_depth_and_size
    deep = ('{"a":' * 40) + '"hunter2"' + ('}' * 40)
    assert_equal "?", mongo(deep)
    wide = %({"filter":{#{(1..9_000).map { |i| %("k#{i}":1) }.join(",")}}})
    assert_equal "?", mongo(wide)
    long = %({"filter":{"a":"#{"x" * 70_000}"}})
    assert_equal "?", mongo(long)
    assert_equal '{"a":["?"]}', mongo(%({"a":[#{(["1"] * 1_000).join(",")}]}))
    assert_equal "?", mongo(%({"a":[#{(["1"] * 8_000).join(",")}]}))
  end

  def test_masked_key_is_shared_with_cache_keys
    assert_equal "views/?", Flare::StoreStatement.masked_key("views/posts/hunter2")
    assert_equal "?", Flare::StoreStatement.masked_key("hunter2")
  end
end
