# frozen_string_literal: true

require_relative "test_helper"

class Sentiero::Rails::SchemaConstraintsTest < Minitest::Test
  def setup
    Sentiero::Rails::Session.delete_all
    Sentiero::Rails::Event.delete_all
    Sentiero::Rails::Problem.delete_all
    Sentiero::Rails::Occurrence.delete_all
    Sentiero::Rails::ServerEvent.delete_all
  end

  def base_problem_attrs(overrides = {})
    {
      fingerprint: "fp1", project: "proj", exception_class: "RuntimeError",
      title: "boom", count: 1, status: "open", first_seen: 1.0, last_seen: 1.0
    }.merge(overrides)
  end

  def test_db_rejects_bad_status_even_when_validation_bypassed
    problem = Sentiero::Rails::Problem.create!(base_problem_attrs)
    assert_raises(ActiveRecord::StatementInvalid) do
      Sentiero::Rails::Problem.where(id: problem.id).update_all(status: "bogus")
    end
  end

  def test_db_rejects_event_without_session
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Sentiero::Rails::Event.create!(
        session_id: "ghost", window_id: "w1", timestamp: 1.0, data: {}, created_at: Time.now
      )
    end
  end

  def test_deleting_session_cascades_to_events
    Sentiero::Rails::Session.create!(session_id: "s1")
    Sentiero::Rails::Event.insert_all([
      {session_id: "s1", window_id: "w1", timestamp: 1.0, data: {}, created_at: Time.now}
    ])
    Sentiero::Rails::Session.where(session_id: "s1").delete_all
    assert_equal 0, Sentiero::Rails::Event.where(session_id: "s1").count
  end

  def test_occurrence_id_unique_at_db_level
    Sentiero::Rails::Occurrence.create!(occurrence_id: "occ1", fingerprint: "fp1", timestamp: 1.0, data: {"a" => 1})
    assert_raises(ActiveRecord::RecordNotUnique) do
      Sentiero::Rails::Occurrence.insert_all!([
        {occurrence_id: "occ1", fingerprint: "fp1", timestamp: 2.0, data: {"a" => 2}}
      ])
    end
  end

  def test_event_id_unique_at_db_level
    Sentiero::Rails::ServerEvent.create!(event_id: "ev1", project: "proj", name: "thing", timestamp: 1.0, data: {"a" => 1})
    assert_raises(ActiveRecord::RecordNotUnique) do
      Sentiero::Rails::ServerEvent.insert_all!([
        {event_id: "ev1", project: "proj", name: "thing", timestamp: 2.0, data: {"a" => 2}}
      ])
    end
  end
end
