# frozen_string_literal: true

require "test_helper"

# Exercises the base Store's abstract error methods + validation helpers via a
# bare subclass that exposes the protected validators.
class ErrorStoreBaseTest < Minitest::Test
  class Bare < Sentiero::Store
    def check_status(s) = validate_status!(s)
    def check_occurrence(o) = validate_occurrence!(o)
    def check_server_event(e) = validate_server_event!(e)
  end

  # A custom store implementing only get_occurrences: count_occurrences is
  # NOT abstract and must work through the default base implementation.
  class OccurrencesOnly < Sentiero::Store
    ROWS = [{"timestamp" => 1.0}, {"timestamp" => 2.0}, {"timestamp" => 3.0}].freeze

    def get_occurrences(problem_id, after: nil, limit: nil)
      rows = ROWS
      rows = rows.select { |row| row["timestamp"] > after.to_f } if after
      limit ? rows.first(limit) : rows
    end
  end

  def setup
    @store = Bare.new
  end

  def test_abstract_methods_raise
    assert_raises(NoMethodError) { @store.save_occurrence({}) }
    assert_raises(NoMethodError) { @store.list_problems(project: "p", limit: 10) }
    assert_raises(NoMethodError) { @store.get_problem("x") }
    assert_raises(NoMethodError) { @store.get_occurrences("x") }
    assert_raises(NoMethodError) { @store.update_problem_status("x", "open") }
    assert_raises(NoMethodError) { @store.save_server_event({}) }
    assert_raises(NoMethodError) { @store.list_server_events(project: "p", limit: 10) }
  end

  def test_count_occurrences_default_builds_on_get_occurrences
    store = OccurrencesOnly.new
    assert_equal 3, store.count_occurrences("any")
    assert_equal 1, store.count_occurrences("any", after: 2.0)
  end

  def test_validate_status_accepts_known_statuses
    %w[open resolved ignored].each { |s| assert_nil @store.check_status(s) }
  end

  def test_validate_status_rejects_unknown
    assert_raises(ArgumentError) { @store.check_status("nope") }
  end

  def test_validate_occurrence_requires_fields
    base = {"fingerprint" => "fp1", "project" => "app", "exception_class" => "E",
            "message" => "boom", "timestamp" => 1.0}
    assert_nil @store.check_occurrence(base)
    %w[fingerprint project exception_class message timestamp].each do |key|
      assert_raises(ArgumentError) { @store.check_occurrence(base.reject { |k, _| k == key }) }
    end
  end

  def test_validate_occurrence_rejects_bad_ids
    base = {"fingerprint" => "fp1", "project" => "app", "exception_class" => "E",
            "message" => "boom", "timestamp" => 1.0}
    assert_raises(ArgumentError) { @store.check_occurrence(base.merge("fingerprint" => "bad id!")) }
    assert_raises(ArgumentError) { @store.check_occurrence(base.merge("project" => "bad id!")) }
  end

  def test_validate_server_event_requires_fields
    base = {"project" => "app", "name" => "signup", "timestamp" => 1.0}
    assert_nil @store.check_server_event(base)
    %w[project name timestamp].each do |key|
      assert_raises(ArgumentError) { @store.check_server_event(base.reject { |k, _| k == key }) }
    end
  end

  def test_validate_occurrence_rejects_non_hash
    assert_raises(ArgumentError) { @store.check_occurrence("nope") }
  end

  def test_validate_server_event_rejects_non_hash
    assert_raises(ArgumentError) { @store.check_server_event("nope") }
  end

  def test_validate_server_event_rejects_bad_project_id
    assert_raises(ArgumentError) do
      @store.check_server_event({"project" => "bad id!", "name" => "x", "timestamp" => 1.0})
    end
  end
end
