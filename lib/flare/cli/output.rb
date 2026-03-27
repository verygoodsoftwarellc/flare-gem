# frozen_string_literal: true

module Flare
  module CLI
    module Output
      private

      def color?
        $stdout.tty?
      end

      def green(text)
        color? ? "\e[32m#{text}\e[0m" : text
      end

      def yellow(text)
        color? ? "\e[33m#{text}\e[0m" : text
      end

      def red(text)
        color? ? "\e[31m#{text}\e[0m" : text
      end

      def bold(text)
        color? ? "\e[1m#{text}\e[0m" : text
      end

      def dim(text)
        color? ? "\e[2m#{text}\e[0m" : text
      end

      def checkmark
        green("✓")
      end

      def xmark
        red("✗")
      end

      def warn_mark
        yellow("!")
      end
    end
  end
end
