# frozen_string_literal: true

module Sentiero
  module Rails
    class Problem < ::ActiveRecord::Base
      self.table_name = "sentiero_problems"

      validates :fingerprint, presence: true, uniqueness: true,
        format: {with: Sentiero::Store::VALID_ID}
      validates :project, presence: true, format: {with: Sentiero::Store::VALID_ID}
      validates :exception_class, presence: true
      validates :title, presence: true, length: {maximum: Sentiero::Store::PROBLEM_TITLE_MAX}
      validates :status, inclusion: {in: Sentiero::Store::VALID_STATUS}
      validates :count, numericality: {only_integer: true, greater_than_or_equal_to: 0}
      validates :first_seen, :last_seen, presence: true
    end
  end
end
