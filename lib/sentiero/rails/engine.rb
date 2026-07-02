# frozen_string_literal: true

require_relative "helpers/script_tag_helper"
require_relative "../reporter"
require_relative "../reporter/middleware"

module Sentiero
  module Rails
    class Engine < ::Rails::Engine
      initializer "sentiero.helpers" do
        ActiveSupport.on_load(:action_view) do
          include Sentiero::Rails::Helpers::ScriptTagHelper
        end
      end

      # Reports unhandled exceptions, then re-raises them.
      initializer "sentiero.reporter_middleware" do |app|
        Sentiero::Rails::Engine.insert_reporter_middleware(app)
      end

      def self.insert_reporter_middleware(app)
        return false unless reporter_middleware_enabled?

        # Install whenever opted in — not gated on Reporter.active? at boot, since
        # the user's Reporter.configure runs in an initializer after this one. The
        # middleware is a cheap pass-through and Reporter.notify guards on active?
        # at request time, so an unconfigured reporter just does nothing.
        app.middleware.use Sentiero::Reporter::Middleware
        true
      rescue => e
        warn "[Sentiero::Reporter] middleware auto-install failed: #{e.class}: #{e.message}"
        false
      end

      def self.reporter_middleware_enabled?
        flag = Sentiero::Rails.configuration.reporter_middleware
        return true if flag.nil?
        flag
      end

      initializer "sentiero.default_store" do
        config.after_initialize do
          if Sentiero.configuration.store.nil?
            require_relative "store"
            Sentiero.configuration.store = Sentiero::Rails::Store.new
          end
        end
      end

      rake_tasks do
        load File.expand_path("tasks/sentiero.rake", __dir__)
      end
    end
  end
end
