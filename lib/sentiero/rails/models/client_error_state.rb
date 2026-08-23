# frozen_string_literal: true

module Sentiero
  module Rails
    class ClientErrorState < ::ActiveRecord::Base
      self.table_name = "sentiero_client_error_states"

      validates :group_id, presence: true, uniqueness: true,
        format: {with: Sentiero::Store::VALID_ID}
      validates :status, inclusion: {in: Sentiero::Store::VALID_STATUS}
      validates :changed_at, presence: true
    end
  end
end
