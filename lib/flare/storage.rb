# frozen_string_literal: true

module Flare
  module Storage
    class Base
      def prune(retention_hours:, max_spans:)
        raise NotImplementedError
      end

      def clear_all
        raise NotImplementedError
      end
    end
  end
end
