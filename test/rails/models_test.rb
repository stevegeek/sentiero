# frozen_string_literal: true

require_relative "test_helper"

class Sentiero::Rails::ModelsTest < Minitest::Test
  def setup
    Sentiero::Rails::Session.delete_all
    Sentiero::Rails::Event.delete_all
    Sentiero::Rails::Problem.delete_all
    Sentiero::Rails::Occurrence.delete_all
    Sentiero::Rails::ServerEvent.delete_all
  end

  # --- Session ---

  def test_session_requires_session_id
    session = Sentiero::Rails::Session.new
    refute session.valid?
    assert_includes session.errors.attribute_names, :session_id
  end

  def test_session_session_id_is_unique
    Sentiero::Rails::Session.create!(session_id: "s1")
    dup = Sentiero::Rails::Session.new(session_id: "s1")
    refute dup.valid?
    assert_includes dup.errors.attribute_names, :session_id
  end

  def test_session_allows_non_format_id
    # Recording path is lenient: ids are not format-validated at the model.
    session = Sentiero::Rails::Session.new(session_id: "'; DROP TABLE x; --")
    assert session.valid?
  end

  # --- Event ---

  def test_event_requires_session_and_window_ids
    event = Sentiero::Rails::Event.new
    refute event.valid?
    assert_includes event.errors.attribute_names, :session_id
    assert_includes event.errors.attribute_names, :window_id
  end

  def test_event_valid_with_recording_ids
    # Create the parent session so this holds regardless of the host app's
    # belongs_to_required_by_default setting.
    Sentiero::Rails::Session.create!(session_id: "s1")
    event = Sentiero::Rails::Event.new(session_id: "s1", window_id: "w1", created_at: Time.now)
    assert event.valid?
  end

  # --- Problem ---

  def valid_problem_attrs(overrides = {})
    {
      fingerprint: "fp1", project: "proj", exception_class: "RuntimeError",
      title: "boom", count: 1, status: "open", first_seen: 1.0, last_seen: 1.0
    }.merge(overrides)
  end

  def test_problem_valid_with_full_attrs
    assert Sentiero::Rails::Problem.new(valid_problem_attrs).valid?
  end

  def test_problem_requires_core_fields
    problem = Sentiero::Rails::Problem.new
    refute problem.valid?
    %i[fingerprint project exception_class title first_seen last_seen].each do |attr|
      assert_includes problem.errors.attribute_names, attr
    end
  end

  def test_problem_rejects_status_outside_set
    problem = Sentiero::Rails::Problem.new(valid_problem_attrs(status: "bogus"))
    refute problem.valid?
    assert_includes problem.errors.attribute_names, :status
  end

  def test_problem_accepts_each_valid_status
    Sentiero::Store::VALID_STATUS.each do |status|
      assert Sentiero::Rails::Problem.new(valid_problem_attrs(status: status)).valid?, status
    end
  end

  def test_problem_fingerprint_is_unique
    Sentiero::Rails::Problem.create!(valid_problem_attrs)
    dup = Sentiero::Rails::Problem.new(valid_problem_attrs)
    refute dup.valid?
    assert_includes dup.errors.attribute_names, :fingerprint
  end

  def test_problem_rejects_negative_count
    problem = Sentiero::Rails::Problem.new(valid_problem_attrs(count: -1))
    refute problem.valid?
    assert_includes problem.errors.attribute_names, :count
  end

  def test_problem_rejects_invalid_fingerprint_format
    problem = Sentiero::Rails::Problem.new(valid_problem_attrs(fingerprint: "bad id!"))
    refute problem.valid?
    assert_includes problem.errors.attribute_names, :fingerprint
  end

  def test_problem_rejects_invalid_project_format
    problem = Sentiero::Rails::Problem.new(valid_problem_attrs(project: "bad id!"))
    refute problem.valid?
    assert_includes problem.errors.attribute_names, :project
  end

  # --- Occurrence ---

  def test_occurrence_valid_with_full_attrs
    occ = Sentiero::Rails::Occurrence.new(
      occurrence_id: "occ1", fingerprint: "fp1", timestamp: 1.0, data: {"a" => 1}
    )
    assert occ.valid?
  end

  def test_occurrence_requires_core_fields
    occ = Sentiero::Rails::Occurrence.new
    refute occ.valid?
    %i[occurrence_id fingerprint timestamp data].each do |attr|
      assert_includes occ.errors.attribute_names, attr
    end
  end

  def test_occurrence_id_is_unique
    Sentiero::Rails::Occurrence.create!(occurrence_id: "occ1", fingerprint: "fp1", timestamp: 1.0, data: {"a" => 1})
    dup = Sentiero::Rails::Occurrence.new(occurrence_id: "occ1", fingerprint: "fp1", timestamp: 2.0, data: {"a" => 2})
    refute dup.valid?
    assert_includes dup.errors.attribute_names, :occurrence_id
  end

  def test_occurrence_rejects_invalid_fingerprint_format
    occ = Sentiero::Rails::Occurrence.new(
      occurrence_id: "occ1", fingerprint: "bad id!", timestamp: 1.0, data: {"a" => 1}
    )
    refute occ.valid?
    assert_includes occ.errors.attribute_names, :fingerprint
  end

  # --- ServerEvent ---

  def test_server_event_valid_with_full_attrs
    ev = Sentiero::Rails::ServerEvent.new(
      event_id: "ev1", project: "proj", name: "thing", timestamp: 1.0, data: {"a" => 1}
    )
    assert ev.valid?
  end

  def test_server_event_requires_core_fields
    ev = Sentiero::Rails::ServerEvent.new
    refute ev.valid?
    %i[event_id project name timestamp data].each do |attr|
      assert_includes ev.errors.attribute_names, attr
    end
  end

  def test_server_event_id_is_unique
    Sentiero::Rails::ServerEvent.create!(event_id: "ev1", project: "proj", name: "thing", timestamp: 1.0, data: {"a" => 1})
    dup = Sentiero::Rails::ServerEvent.new(event_id: "ev1", project: "proj", name: "thing", timestamp: 2.0, data: {"a" => 2})
    refute dup.valid?
    assert_includes dup.errors.attribute_names, :event_id
  end

  def test_server_event_rejects_invalid_project_format
    ev = Sentiero::Rails::ServerEvent.new(
      event_id: "ev1", project: "bad id!", name: "thing", timestamp: 1.0, data: {"a" => 1}
    )
    refute ev.valid?
    assert_includes ev.errors.attribute_names, :project
  end
end
