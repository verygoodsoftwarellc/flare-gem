# frozen_string_literal: true

require "strscan"

module Flare
  # Takes the values out of a SQL statement in one left-to-right pass, keeping
  # keywords and names so the same query with different values reads the same.
  #
  # The first delimiter decides the token, so a quote inside a comment or a
  # comment marker inside a string can't change how the rest is read. When the
  # scan can't tell where a value ends (an unterminated literal or comment, or a
  # backslash before a quote, which means different things across databases and
  # server settings), everything after that point is masked.
  module SqlMask
    PLACEHOLDER = "?"

    # Longer statements are masked up to here and cut, which bounds the work.
    MAX_BYTES = 16_384
    TRUNCATED = " ..."

    # Systems known to speak SQL. Anything else may not follow its quoting rules,
    # so callers keep only a command word. No system at all is read as SQL, with
    # every quote treated as a value.
    SQL_SYSTEMS = /postgres|postgis|mysql|trilogy|maria|sqlite|cockroach|sqlserver|mssql|oracle|db2/i

    # Close enough to SQL to mask, with rules that vary: every quoted string counts
    # as a value, and # and // start comments that run to the end of the line.
    # Backticks hold names only where that's known.
    SQL_LIKE_SYSTEMS = /cassandra|clickhouse|bigquery|snowflake/i
    BACKTICK_NAMES = /clickhouse|bigquery/i

    # Double quotes hold names on these. On MySQL they hold values, and elsewhere
    # they're treated as values too. SQLite reads them as values when no such
    # column exists, so it keeps them only in places that can't hold a value.
    # MySQL also starts comments with #, which is an operator on Postgres.
    DOUBLE_QUOTED_NAMES = /postgres|postgis|cockroach|oracle|db2/i
    SQLITE = /sqlite/i
    HASH_COMMENTS = /mysql|trilogy|maria/i

    COMMAND_WORD = /\A\s*([A-Za-z][A-Za-z_.]{0,31})(?=\s|\z)/
    OPERATION_WORD = /\A[A-Za-z][A-Za-z_.]{0,31}\z/
    # Decided from a short tail of the output, so anything spaced too widely to see
    # in it isn't a name. FROM counts only with the word before it in view, because
    # IS DISTINCT FROM takes a value.
    NAME_POSITION = /(?:\b(?:JOIN|INTO|UPDATE|TABLE)\s{1,8}|\.)\z/ni
    FROM_POSITION = /(\S+)\s{1,8}FROM\s{1,8}\z/ni
    DISTINCT_WORD = /DISTINCT\z/ni
    DOUBLE_QUOTED = /"[^"]*+(?:""[^"]*+)*+"/n
    QUALIFIER = /#{DOUBLE_QUOTED.source}(?=\.(?:\*|\w|#{DOUBLE_QUOTED.source}))/n

    WORD = /[A-Za-z_\x80-\xff][\w$\x80-\xff]*+/n
    NUMBER = /\.?\d[\w.\x80-\xff]*+(?:(?<=[eE])[+-]\d++)?/n
    DOLLAR_OTHER = /\$\d*+/n
    DOLLAR_TAG = /\$(?:[A-Za-z_\x80-\xff][\w\x80-\xff]*+)?\$/n
    LINE_COMMENT = /(?:--|#|\/\/)[^\n]*+/n
    COMMENT_START = %r{/\*}n
    COMMENT_EDGE = %r{/\*|\*/}n
    LITERAL_PREFIX = /\A(?:[xXbBnNeE]|_\w+)\z/n
    LITERAL_RUNS = { "'" => /[^'\\]*+/n, '"' => /[^"\\]*+/n, "`" => /[^`\\]*+/n }.freeze
    IN_LIST = /\bIN ?\( ?\?(?: ?, ?\?)* ?\)/ni
    OTHER_WHITESPACE = "\t\n\r\f\v"

    # A run of tokens that are copied as they are, matched in one go because most
    # of a statement is this. It stops at anything that needs a decision: a quote,
    # a number, a $, a comment, or a word that may be a literal's prefix.
    word = %q{[A-Za-z_\x80-\xff][\w$\x80-\xff]*+(?!')}
    other = %q{[^\w\x80-\xff'"`$#./-]++|\.(?!\d)|-(?!-)}
    backtick = "`[^`]*+(?:``[^`]*+)*+`"
    plain = "#{word}|#{other}|#{backtick}|/(?!\\*)"
    PLAIN = Regexp.new("(?:#{plain})++", Regexp::NOENCODING)
    PLAIN_NAMES = Regexp.new(%((?:#{plain}|#{DOUBLE_QUOTED.source}|#)++), Regexp::NOENCODING)
    PLAIN_HASH = Regexp.new("(?:#{plain}|#)++", Regexp::NOENCODING)
    PLAIN_LIKE = Regexp.new("(?:#{word}|#{other}|/(?![*/]))++", Regexp::NOENCODING)
    PLAIN_LIKE_BACKTICKS = Regexp.new("(?:#{word}|#{other}|#{backtick}|/(?![*/]))++", Regexp::NOENCODING)

    module_function

    def sql_system?(system)
      system.to_s.empty? || SQL_SYSTEMS.match?(system.to_s) || SQL_LIKE_SYSTEMS.match?(system.to_s)
    end

    # The first word of a statement, if it could be a command name. Nil otherwise.
    def command_word(statement)
      statement.to_s[COMMAND_WORD, 1]
    end

    # The value if all of it could be an operation name. Nil otherwise.
    def operation_word(value)
      value.to_s[OPERATION_WORD]
    end

    def mask(statement, system = nil)
      sql = statement.to_s.b
      truncated = sql.bytesize > MAX_BYTES
      sql = sql.byteslice(0, MAX_BYTES) if truncated
      out = scan(StringScanner.new(sql), system.to_s)
      out.tr!(OTHER_WHITESPACE, " ")
      out.squeeze!(" ")
      out.gsub!(IN_LIST, "IN (?)")
      out.strip!
      out << TRUNCATED if truncated
      out.force_encoding(Encoding::UTF_8).scrub!
    end

    def scan(scanner, system)
      sqlite = SQLITE.match?(system)
      plain = if SQL_LIKE_SYSTEMS.match?(system) then BACKTICK_NAMES.match?(system) ? PLAIN_LIKE_BACKTICKS : PLAIN_LIKE
      elsif DOUBLE_QUOTED_NAMES.match?(system) then PLAIN_NAMES
      elsif system.empty? || HASH_COMMENTS.match?(system) then PLAIN
      else PLAIN_HASH
      end
      out = String.new(capacity: scanner.string.bytesize, encoding: Encoding::BINARY)

      until scanner.eos?
        if (run = scanner.scan(plain))
          out << run
        elsif scanner.skip(NUMBER)
          out << PLACEHOLDER
        elsif (word = scanner.scan(WORD))
          if LITERAL_PREFIX.match?(word)
            mask_literal(scanner, out, backslash_escapes: word.casecmp?("e"))
          else
            out << word
          end
        else
          scan_delimiter(scanner, out, plain, sqlite)
        end
      end

      out
    end

    # Handles the delimiter the plain run stopped on. Giving up on the rest of the
    # statement means terminating the scanner, which ends the loop above.
    def scan_delimiter(scanner, out, plain, sqlite)
      case scanner.peek(1)
      when "'"
        mask_literal(scanner, out)
      when '"'
        # A closed name would already be part of the plain run where quotes are names.
        if plain == PLAIN_NAMES then mask_rest(scanner, out)
        elsif sqlite && (name = sqlite_name(scanner, out)) then out << name
        else mask_literal(scanner, out)
        end
      when "`"
        # Likewise, where backticks are names.
        plain == PLAIN_LIKE ? mask_literal(scanner, out) : mask_rest(scanner, out)
      when "$"
        mask_dollar(scanner, out)
      when "/"
        if scanner.check(COMMENT_START)
          skip_comment(scanner, out)
        else
          scanner.skip(LINE_COMMENT)
          out << " "
        end
      else # -- or, where it starts a comment, #
        scanner.skip(LINE_COMMENT)
        out << " "
      end
    end

    # A quoted word right after FROM and the like, or either side of a dot, can
    # only be a name.
    def sqlite_name(scanner, out)
      tail = out.byteslice(-32, 32) || out
      from = FROM_POSITION.match(tail)
      if NAME_POSITION.match?(tail) || (from && !DISTINCT_WORD.match?(from[1]))
        scanner.scan(DOUBLE_QUOTED)
      else
        scanner.scan(QUALIFIER)
      end
    end

    def mask_rest(scanner, out)
      out << PLACEHOLDER
      scanner.terminate
    end

    # The scanner is on the opening quote. Reads to the closing one, or masks the
    # rest if there isn't one.
    #
    # An even run of backslashes before a quote closes the literal whether or not
    # the server treats backslash as an escape. An odd run only closes it if the
    # server doesn't, and that depends on the database and its settings, so the
    # literal counts as unterminated. Only E'' strings say for themselves.
    def mask_literal(scanner, out, backslash_escapes: false)
      quote = scanner.getch
      plain = LITERAL_RUNS.fetch(quote)
      out << PLACEHOLDER

      loop do
        scanner.skip(plain)
        return scanner.terminate if scanner.eos?

        if scanner.peek(1) == "\\"
          if backslash_escapes
            scanner.skip(/\\.?/mn)
          else
            run = scanner.skip(/\\+/n)
            return scanner.terminate if run.odd? && scanner.peek(1) == quote
          end
        else
          scanner.getch
          return unless scanner.peek(1) == quote

          scanner.getch
        end
      end
    end

    def mask_dollar(scanner, out)
      out << PLACEHOLDER
      if (tag = scanner.scan(DOLLAR_TAG))
        scanner.terminate unless scanner.skip_until(Regexp.new(Regexp.escape(tag), Regexp::NOENCODING))
      else
        scanner.skip(DOLLAR_OTHER)
      end
    end

    # Comments nest on Postgres. Reading them that way elsewhere can only mask
    # more, never less.
    def skip_comment(scanner, out)
      scanner.skip(COMMENT_START)
      depth = 1
      while depth.positive?
        return scanner.terminate unless scanner.skip_until(COMMENT_EDGE)

        depth += scanner.matched == "/*" ? 1 : -1
      end
      out << " "
    end

    private_class_method :scan, :scan_delimiter, :sqlite_name, :mask_rest, :mask_literal, :mask_dollar, :skip_comment
  end
end
