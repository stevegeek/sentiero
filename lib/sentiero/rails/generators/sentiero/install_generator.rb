# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"
require "securerandom"

module Sentiero
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      include ::Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates a Sentiero initializer and migration for ActiveRecord storage."

      def self.next_migration_number(dirname)
        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end

      def create_migration_file
        migration_template "create_sentiero_tables.rb.erb",
          "db/migrate/create_sentiero_tables.rb"
      end

      def create_initializer
        template "initializer.rb", "config/initializers/sentiero.rb"
      end

      def show_route_instructions
        say ""
        say "Sentiero installed successfully!", :green
        say ""
        say "Next steps:", :yellow
        say "  1. Run migrations:  rails db:migrate"
        say "  2. Mount the Rack apps in config/routes.rb:"
        say ""
        say "    # config/routes.rb"
        say '    mount Sentiero::Web::EventsApp.new, at: "/sentiero/events"'
        say '    mount Sentiero::Web::DashboardApp.new, at: "/sentiero"'
        say ""
        say "  3. Add the script tag to your layout:"
        say "    <%= sentiero_script_tag %>"
        say ""
        password = SecureRandom.urlsafe_base64(12)
        say "Dashboard auth is ENABLED by default (HTTP Basic, user \"admin\").", :yellow
        say "Set this generated password in your environment:"
        say ""
        say "    export SENTIERO_DASHBOARD_PASSWORD=#{password}"
        say ""
        say "The dashboard refuses to load until SENTIERO_DASHBOARD_PASSWORD is set."
        say "To disable auth, comment out config.basic_auth in config/initializers/sentiero.rb."
        say ""
      end
    end
  end
end
