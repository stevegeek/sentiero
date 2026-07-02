# frozen_string_literal: true

ActiveRecord::Schema.define do
  create_table :sentiero_sessions, force: true do |t|
    t.string :session_id, null: false
    t.json :metadata
    t.timestamps
  end

  add_index :sentiero_sessions, :session_id, unique: true

  create_table :sentiero_events, force: true do |t|
    t.string :session_id, null: false
    t.string :window_id, null: false
    t.float :timestamp
    t.json :data
    t.datetime :created_at, null: false
  end

  add_index :sentiero_events, [:session_id, :window_id, :timestamp],
    name: "index_sentiero_events_on_session_window_timestamp"
  add_index :sentiero_events, :session_id,
    name: "index_sentiero_events_on_session_id"

  create_table :sentiero_problems, force: true do |t|
    t.string :fingerprint, null: false
    t.string :project, null: false
    t.string :exception_class, null: false
    t.string :title, null: false
    t.string :message
    t.integer :count, null: false, default: 0
    t.string :status, null: false, default: "open"
    t.float :first_seen, null: false
    t.float :last_seen, null: false
    t.float :resolved_at
  end

  add_index :sentiero_problems, :fingerprint, unique: true,
    name: "index_sentiero_problems_on_fingerprint"
  add_index :sentiero_problems, :project,
    name: "index_sentiero_problems_on_project"
  add_index :sentiero_problems, :status,
    name: "index_sentiero_problems_on_status"
  add_index :sentiero_problems, :last_seen,
    name: "index_sentiero_problems_on_last_seen"

  create_table :sentiero_occurrences, force: true do |t|
    t.string :occurrence_id, null: false
    t.string :fingerprint, null: false
    t.string :session_id
    t.float :timestamp, null: false
    t.json :data, null: false
  end

  add_index :sentiero_occurrences, [:fingerprint, :timestamp],
    name: "index_sentiero_occurrences_on_fingerprint_timestamp"
  add_index :sentiero_occurrences, :session_id,
    name: "index_sentiero_occurrences_on_session_id"
  add_index :sentiero_occurrences, :occurrence_id, unique: true,
    name: "index_sentiero_occurrences_on_occurrence_id"

  create_table :sentiero_server_events, force: true do |t|
    t.string :event_id, null: false
    t.string :project, null: false
    t.string :name, null: false
    t.string :level
    t.string :session_id
    t.float :timestamp, null: false
    t.json :data, null: false
  end

  add_index :sentiero_server_events, :project,
    name: "index_sentiero_server_events_on_project"
  add_index :sentiero_server_events, :session_id,
    name: "index_sentiero_server_events_on_session_id"
  add_index :sentiero_server_events, :event_id, unique: true,
    name: "index_sentiero_server_events_on_event_id"

  add_check_constraint :sentiero_problems, "status IN ('open', 'resolved', 'ignored')",
    name: "sentiero_problems_status_check"

  add_foreign_key :sentiero_events, :sentiero_sessions,
    column: :session_id, primary_key: :session_id, on_delete: :cascade
end
