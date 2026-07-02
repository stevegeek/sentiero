# frozen_string_literal: true

require_relative "config/environment"

# Auto-create tables if they don't exist
unless ActiveRecord::Base.connection.table_exists?(:sentiero_sessions)
  load File.expand_path("db/schema.rb", Rails.root)
end

run Rails.application
