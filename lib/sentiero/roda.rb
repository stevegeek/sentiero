# frozen_string_literal: true

require "sentiero"

class Roda
  module RodaPlugins
    module Sentiero
      def self.configure(_app, **opts)
        config = ::Sentiero.configuration
        opts.each do |key, value|
          setter = :"#{key}="
          config.public_send(setter, value) if config.respond_to?(setter)
        end
      end

      module RequestMethods
        def sentiero_events
          run ::Sentiero::Web::EventsApp.new
        end

        def sentiero_assets
          run ::Sentiero::Web::AssetsApp.new
        end

        def sentiero_dashboard
          run ::Sentiero::Web::DashboardApp.new
        end

        def sentiero_analytics
          run ::Sentiero::Web::AnalyticsApp.new
        end

        def sentiero_monitoring
          run ::Sentiero::Web::MonitoringApp.new
        end
      end

      module InstanceMethods
        def sentiero_script_tag(events_url:, recorder_url: nil)
          ::Sentiero::Web::ScriptTag.render(events_url: events_url, recorder_url: recorder_url)
        end
      end
    end

    register_plugin(:sentiero, Sentiero)
  end
end
