# frozen_string_literal: true

module Flare
  module Storage
    class Base
      def save_case(attributes)
        raise NotImplementedError
      end

      def save_clues(clues)
        raise NotImplementedError
      end

      def find_case(uuid)
        raise NotImplementedError
      end

      def list_cases(type: nil, status: nil, method: nil, name: nil, origin: nil, limit: 50, offset: 0)
        raise NotImplementedError
      end

      def clues_for_case(case_uuid)
        raise NotImplementedError
      end

      def list_clues(type: nil, search: nil, limit: 50, offset: 0)
        raise NotImplementedError
      end

      def find_clue(id)
        raise NotImplementedError
      end

      def prune(retention_hours:, max_cases:)
        raise NotImplementedError
      end

      def clear_all
        raise NotImplementedError
      end

      def count_cases(type: nil, status: nil, method: nil, name: nil, origin: nil)
        raise NotImplementedError
      end

      def count_clues(type: nil, search: nil)
        raise NotImplementedError
      end
    end
  end
end

  # storage/sqlite is loaded on demand when spans are enabled
  # to avoid requiring sqlite3 in production environments
