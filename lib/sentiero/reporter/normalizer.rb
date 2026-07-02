# frozen_string_literal: true

module Sentiero
  module Reporter
    module Normalizer
      module_function

      def stringify_shallow(hash)
        return {} unless hash.is_a?(Hash)
        hash.transform_keys(&:to_s)
      end
    end
  end
end
