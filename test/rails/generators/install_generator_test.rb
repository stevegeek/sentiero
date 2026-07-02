# frozen_string_literal: true

require_relative "../test_helper"
require "rails/generators/test_case"
require "sentiero/rails/generators/sentiero/install_generator"

class Sentiero::Generators::InstallGeneratorTest < ::Rails::Generators::TestCase
  tests Sentiero::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generator_test", __dir__)

  setup do
    prepare_destination
  end

  test "creates migration file" do
    run_generator

    assert_migration "db/migrate/create_sentiero_tables.rb" do |migration|
      assert_match(/create_table :sentiero_sessions/, migration)
      assert_match(/create_table :sentiero_events/, migration)
      assert_match(/t\.string :session_id, null: false/, migration)
      assert_match(/t\.string :window_id, null: false/, migration)
      assert_match(/t\.float :timestamp/, migration)
      assert_match(/t\.json :data/, migration)
      assert_match(/add_index :sentiero_sessions, :session_id, unique: true/, migration)
      assert_match(/index_sentiero_events_on_session_window_timestamp/, migration)
    end
  end

  test "creates initializer file with active basic_auth block" do
    run_generator

    assert_file "config/initializers/sentiero.rb" do |initializer|
      assert_match(/Sentiero\.configure/, initializer)
      assert_match(/config\.basic_auth = \{/, initializer)
      assert_match(/ENV\["SENTIERO_DASHBOARD_PASSWORD"\]/, initializer)
      assert_match(/auth_callback/, initializer)
      refute_match(/dashboard is NOT authenticated/, initializer)
    end
  end

  test "prints a generated dashboard password in the install output" do
    output = run_generator
    assert_match(/SENTIERO_DASHBOARD_PASSWORD/, output)
    assert_match(/export SENTIERO_DASHBOARD_PASSWORD=/, output)
  end

  test "initializer includes commented reporter configuration block" do
    run_generator

    assert_file "config/initializers/sentiero.rb" do |initializer|
      assert_match(/Sentiero::Reporter\.configure do \|r\|/, initializer)
      assert_match(/r\.endpoint/, initializer)
      assert_match(/r\.ingest_key/, initializer)
      assert_match(/r\.project/, initializer)
      assert_match(/r\.environment/, initializer)
      assert_match(/r\.release/, initializer)
      assert_match(/ignore_exceptions/, initializer)
      assert_match(/before_notify/, initializer)
      assert_match(/config\.reporter_middleware/, initializer)
    end
  end
end
