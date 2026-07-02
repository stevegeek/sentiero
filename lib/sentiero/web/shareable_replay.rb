# frozen_string_literal: true

require "json"
require_relative "base_app"
require_relative "manifest"

module Sentiero
  module Web
    # Builds a single self-contained HTML document for a whole session, inlining
    # the rrweb-player JS/CSS and the session's events so it replays offline with
    # no server. #html returns the document, or nil when there's nothing to replay.
    #
    # Events are inlined as a <script type="application/json"> blob escaped via
    # escape_json so a </script> in the data cannot break out of the script context.
    class ShareableReplay
      include Escaping

      def initialize(store, session_id)
        @store = store
        @session_id = session_id
      end

      def html
        session = @store.get_session(@session_id)
        return nil if session.nil?

        windows = session[:windows] || []
        return nil if windows.empty?

        events = collect_events(windows)
        return nil if events.empty?

        build_html(events)
      end

      private

      # rrweb replays a flat, time-ordered stream, so all windows are merged
      # and sorted by timestamp into one timeline.
      def collect_events(windows)
        windows
          .flat_map { |window| @store.get_events(Sentiero::WindowRef.new(@session_id, window[:window_id])) }
          .sort_by { |event| event["timestamp"] || 0 }
      end

      def build_html(events)
        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Sentiero session #{escape_html(@session_id)}</title>
          <style>#{read_asset("rrweb-player-css")}</style>
          <style>body{margin:0;background:#1a1a1a}#sentiero-player{display:flex;justify-content:center;padding:16px}</style>
          </head>
          <body>
          <div id="sentiero-player"></div>
          <script type="application/json" id="sentiero-events">#{escape_json(JSON.generate(events))}</script>
          <script>#{read_asset("rrweb-player")}</script>
          <script>#{bootloader}</script>
          </body>
          </html>
        HTML
      end

      # JSON.parse safely round-trips the escape_json transform, which only
      # touched <, >, & and the JS line separators (all valid in JSON strings).
      def bootloader
        <<~JS
          (function () {
            var events = JSON.parse(document.getElementById("sentiero-events").textContent);
            var Player = rrwebPlayer.default || rrwebPlayer;
            new Player({
              target: document.getElementById("sentiero-player"),
              props: { events: events, autoPlay: false }
            });
          })();
        JS
      end

      def read_asset(logical_name)
        filename = Manifest.manifest.fetch(logical_name)
        File.read(File.join(BaseApp::ASSETS_DIR, filename))
      end
    end
  end
end
