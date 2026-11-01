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

    # Double quotes hold values on MySQL and names elsewhere. MySQL also starts
    # comments with #, which is an operator on Postgres. With no system to go on,
    # read them as values.
    MYSQL = /mysql|trilogy|maria/i

    WORD = /[A-Za-z_\x80-\xff][\w$\x80-\xff]*+/n
    NUMBER = /\.?\d[\w.\x80-\xff]*+(?:(?<=[eE])[+-]\d++)?/n
    DOLLAR_OTHER = /\$\d*+/n
    DOLLAR_TAG = /\$(?:[A-Za-z_\x80-\xff][\w\x80-\xff]*+)?\$/n
    LINE_COMMENT = /(?:--|#)[^\n]*+/n
    COMMENT_START = %r{/\*}n
    COMMENT_EDGE = %r{/\*|\*/}n
    LITERAL_PREFIX = /\A(?:[xXbBnNeE]|_\w+)\z/n
    IN_LIST = /\bIN ?\( ?\?(?: ?, ?\?)* ?\)/ni
    OTHER_WHITESPACE = "\t\n\r\f\v"

    # A run of tokens that are copied as they are, matched in one go because most
    # of a statement is this. It stops at anything that needs a decision: a quote,
    # a number, a $, a comment, or a word that may be a literal's prefix.
    plain = <<~'PATTERN'.delete("\n")
      [A-Za-z_\x80-\xff][\w$\x80-\xff]*+(?!')
      |[^\w\x80-\xff'"`$#./-]++
      |`[^`]*+(?:``[^`]*+)*+`
      |\.(?!\d)
      |-(?!-)
      |/(?!\*)
    PATTERN
    PLAIN_MYSQL = Regexp.new("(?:#{plain})++", Regexp::NOENCODING)
    PLAIN_OTHER = Regexp.new(%((?:#{plain}|"[^"]*+(?:""[^"]*+)*+"|#)++), Regexp::NOENCODING)

    module_function

    def mask(statement, system = nil)
      sql = statement.to_s.b
      truncated = sql.bytesize > MAX_BYTES
      sql = sql.byteslice(0, MAX_BYTES) if truncated
      mysql = system.to_s.empty? || MYSQL.match?(system.to_s)

      out = scan(StringScanner.new(sql), mysql)
      out.tr!(OTHER_WHITESPACE, " ")
      out.squeeze!(" ")
      out.gsub!(IN_LIST, "IN (?)")
      out.strip!
      out << TRUNCATED if truncated
      out.force_encoding(Encoding::UTF_8).scrub!
    end

    def scan(scanner, mysql)
      plain = mysql ? PLAIN_MYSQL : PLAIN_OTHER
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
          scan_delimiter(scanner, out, mysql)
        end
      end

      out
    end

    # Handles the delimiter the plain run stopped on. Giving up on the rest of the
    # statement means terminating the scanner, which ends the loop above.
    def scan_delimiter(scanner, out, mysql)
      case scanner.peek(1)
      when "'"
        mask_literal(scanner, out)
      when '"'
        # A closed name would have been part of the plain run on other systems.
        mysql ? mask_literal(scanner, out) : mask_rest(scanner, out)
      when "`"
        # Likewise: only an unterminated name gets here.
        mask_rest(scanner, out)
      when "$"
        mask_dollar(scanner, out)
      when "/"
        skip_comment(scanner, out)
      else # -- or, on MySQL only, #
        scanner.skip(LINE_COMMENT)
        out << " "
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
      plain = quote == "'" ? /[^'\\]*+/n : /[^"\\]*+/n
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

    private_class_method :scan, :scan_delimiter, :mask_rest, :mask_literal, :mask_dollar, :skip_comment
  end
end
