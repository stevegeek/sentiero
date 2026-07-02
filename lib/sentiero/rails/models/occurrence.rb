# frozen_string_literal: true

module Sentiero
  module Rails
    class Occurrence < ::ActiveRecord::Base
      self.table_name = "sentiero_occurrences"

      validates :occurrence_id, presence: true, uniqueness: true
      validates :fingerprint, presence: true, format: {with: Sentiero::Store::VALID_ID}
      validates :timestamp, presence: true
      validates :data, presence: true
    end
  end
end
