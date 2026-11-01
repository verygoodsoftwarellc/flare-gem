# frozen_string_literal: true

require "json"
require "set"

require_relative "utf8"

module Flare
  # The shape of a Redis or MongoDB statement with its values taken out. Keeps what
  # groups calls together: the command, a key's first segment, a document's
  # structure. Anything it can't read comes out as a placeholder.
  module StoreStatement
    PLACEHOLDER = "?"
    MORE = "..."
    MAX_REDIS_LINES = 10
    MAX_REDIS_BYTES = 16_384
    MAX_MONGO_BYTES = 65_536
    MAX_MONGO_DEPTH = 16
    MAX_MONGO_NODES = 5_000

    KEY_NAMESPACE = /\A[A-Za-z][A-Za-z_-]{0,40}(?=[\/:])/

    # Commands whose first argument is a key.
    KEY_COMMANDS = %w[
      APPEND DECR DECRBY DEL EXISTS EXPIRE EXPIREAT GET GETDEL GETEX GETRANGE GETSET HDEL HEXISTS HGET HGETALL
      HINCRBY HINCRBYFLOAT HKEYS HLEN HMGET HMSET HSCAN HSET HSETNX HSTRLEN HVALS INCR INCRBY INCRBYFLOAT LINDEX
      LINSERT LLEN LMOVE LPOP LPOS LPUSH LPUSHX LRANGE LREM LSET LTRIM MGET MSET MSETNX PERSIST PEXPIRE PEXPIREAT
      PFADD PFCOUNT PSETEX PTTL RENAME RENAMENX RPOP RPUSH RPUSHX SADD SCARD SDIFF SET SETEX SETNX SETRANGE SINTER
      SISMEMBER SMEMBERS SMISMEMBER SPOP SRANDMEMBER SREM SSCAN STRLEN SUBSTR SUNION TOUCH TTL TYPE UNLINK XACK XADD
      XDEL XLEN XRANGE XREVRANGE XTRIM ZADD ZCARD ZCOUNT ZINCRBY ZLEXCOUNT ZMSCORE ZPOPMAX ZPOPMIN ZRANGE
      ZRANGEBYLEX ZRANGEBYSCORE ZRANK ZREM ZREMRANGEBYRANK ZREMRANGEBYSCORE ZREVRANGE ZREVRANGEBYSCORE ZREVRANK
      ZSCAN ZSCORE
    ].to_set.freeze

    # Commands whose arguments aren't kept.
    OTHER_COMMANDS = %w[
      ACL ASKING AUTH BGSAVE BITCOUNT BLMOVE BLPOP BRPOP BZPOPMAX BZPOPMIN CLIENT CLUSTER COMMAND CONFIG COPY DBSIZE
      DISCARD DUMP ECHO EVAL EVALSHA EVALSHA_RO EVAL_RO EXEC FCALL FLUSHALL FLUSHDB FUNCTION GEOADD GEODIST GEOHASH
      GEOPOS GEOSEARCH GETBIT HELLO INFO KEYS LASTSAVE MEMORY MIGRATE MODULE MONITOR MOVE MULTI OBJECT PING PSUBSCRIBE
      PUBLISH PUBSUB PUNSUBSCRIBE QUIT RANDOMKEY READONLY READWRITE RESET RESTORE ROLE SAVE SCAN SCRIPT SELECT SETBIT
      SHUTDOWN SLAVEOF SLOWLOG SORT SPUBLISH SSUBSCRIBE SUBSCRIBE SUNSUBSCRIBE SWAPDB TIME UNSUBSCRIBE UNWATCH WAIT
      WATCH XAUTOCLAIM XCLAIM XGROUP XINFO XPENDING XREAD XREADGROUP
    ].to_set.freeze
    MODULE_COMMAND = /\A[A-Z]+\.[A-Z]+\z/

    COLLECTION_COMMANDS = %w[
      find count distinct aggregate insert update delete findAndModify findandmodify getMore create drop listIndexes
      createIndexes dropIndexes
    ].to_set.freeze
    COLLECTION_NAME = /\A[\w.-]{1,64}\z/
    MONGO_KEY = /\A\$?[A-Za-z_][\w-]{0,63}\z/

    class TooLarge < StandardError; end

    module_function

    # A key's leading word and separator, like views/? or session:?.
    def masked_key(key)
      namespace = key[KEY_NAMESPACE]
      namespace ? "#{namespace}#{key[namespace.length]}#{PLACEHOLDER}" : PLACEHOLDER
    end

    # The instrumentation joins a pipeline's commands with line breaks and a
    # command's arguments with spaces, so a line break can also sit inside a value.
    # Only a pipeline is read line by line, and only lines that start with a Redis
    # command count. A script can't be told from its arguments, so it's left out.
    def redis(statement, pipelined: true)
      text = UTF8.scrub(statement.to_s.byteslice(0, MAX_REDIS_BYTES))
      lines = pipelined ? text.split("\n") : [text.split("\n", 2).first.to_s]

      shapes = []
      more = false
      lines.each do |line|
        more = true if line == MORE
        shape = redis_line(line)
        next if shape.nil? || shapes.last == shape
        break more = true if shapes.size == MAX_REDIS_LINES

        shapes << shape
      end

      return PLACEHOLDER if shapes.empty?

      shapes << MORE if more
      shapes.join("\n")
    end

    def redis_line(line)
      command, key = line.split(" ", 3)
      return unless command

      command = command.upcase
      if KEY_COMMANDS.include?(command)
        key ? "#{command} #{masked_key(key)}" : command
      elsif OTHER_COMMANDS.include?(command) || MODULE_COMMAND.match?(command)
        key ? "#{command} #{PLACEHOLDER}" : command
      end
    end

    # Keeps the structure of a command's JSON and masks every value. Only a leading
    # command keeps its value, the collection name.
    def mongo(statement)
      text = statement.to_s
      return PLACEHOLDER if text.empty? || text.bytesize > MAX_MONGO_BYTES

      document = JSON.parse(text, max_nesting: MAX_MONGO_DEPTH)
      return PLACEHOLDER unless document.is_a?(Hash)

      budget = [MAX_MONGO_NODES]
      masked = mongo_value(document, budget)
      command, collection = document.first
      if COLLECTION_COMMANDS.include?(command) && collection.is_a?(String) && COLLECTION_NAME.match?(collection)
        masked[mongo_key(command)] = collection
      end
      JSON.generate(masked)
    rescue JSON::ParserError, JSON::NestingError, EncodingError, TooLarge, ArgumentError
      PLACEHOLDER
    end

    def mongo_value(value, budget)
      raise TooLarge if (budget[0] -= 1).negative?

      case value
      when Hash then value.each_with_object({}) { |(key, item), out| out[mongo_key(key)] = mongo_value(item, budget) }
      when Array then value.map { |item| mongo_value(item, budget) }.uniq
      else PLACEHOLDER
      end
    end

    def mongo_key(key)
      head, dot, = key.partition(".")
      return PLACEHOLDER unless MONGO_KEY.match?(head)

      dot.empty? ? head : "#{head}.#{PLACEHOLDER}"
    end

    private_class_method :redis_line, :mongo_value, :mongo_key
  end
end
