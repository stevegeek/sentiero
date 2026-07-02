# frozen_string_literal: true

module Sentiero
  module Rails
    class Event < ::ActiveRecord::Base
      self.table_name = "sentiero_events"

      belongs_to :session,
        class_name: "Sentiero::Rails::Session",
        primary_key: :session_id,
        inverse_of: false

      validates :session_id, :window_id, presence: true
    end
  end
end
