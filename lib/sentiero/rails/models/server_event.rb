# frozen_string_literal: true

module Sentiero
  module Rails
    class ServerEvent < ::ActiveRecord::Base
      self.table_name = "sentiero_server_events"

      validates :event_id, presence: true, uniqueness: true
      validates :project, presence: true, format: {with: Sentiero::Store::VALID_ID}
      validates :name, presence: true
      validates :timestamp, presence: true
      validates :data, presence: true
    end
  end
end
