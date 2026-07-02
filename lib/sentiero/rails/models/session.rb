# frozen_string_literal: true

module Sentiero
  module Rails
    class Session < ::ActiveRecord::Base
      self.table_name = "sentiero_sessions"

      has_many :events,
        class_name: "Sentiero::Rails::Event",
        primary_key: :session_id,
        dependent: :delete_all,
        inverse_of: false

      validates :session_id, presence: true, uniqueness: true
    end
  end
end
