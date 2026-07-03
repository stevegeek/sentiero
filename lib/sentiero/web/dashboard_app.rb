# frozen_string_literal: true

require_relative "base_app"
require_relative "analytics_app"
require_relative "monitoring_app"

module Sentiero
  module Web
    class DashboardApp < BaseApp
      def initialize
        super
        BaseApp.warn_unauthenticated_once
      end

      def call(env)
        # Rack::Builder#map "/sentiero" leaves PATH_INFO empty (not "/") for a
        # request to the bare mount point; treat it as the index.
        path = env["PATH_INFO"]
        path = "/" if path.nil? || path.empty?
        method = env["REQUEST_METHOD"]

        # Static assets are served before auth: they carry no session data, and
        # the standalone AssetsApp endpoint serves the same files unauthenticated.
        if (asset_path = path[%r{\A/assets/(.+)\z}, 1])
          return handle_asset(asset_path)
        end

        # Stable alias for the content-hashed recorder bundle, so pages outside
        # the Ruby helpers (static HTML) can hardcode one URL that survives
        # rebuilds. Sibling of the /events mount, so the recorder's
        # currentScript fallback derives eventsUrl correctly from it.
        return handle_recorder_alias if path == "/recorder.js"

        return unauthorized_response unless authorized?(env)

        case path
        when "/"
          handle_index(env)
        when %r{\A/sessions/([^/]+)/windows/([^/]+)\z}
          sid, wid = $1, $2
          guard(sid, wid) ||
            (delete_request?(method, env) ? handle_delete_window(env, sid, wid) : handle_show(env, sid, wid))
        when %r{\A/api/sessions/([^/]+)/windows/([^/]+)/events\z}
          sid, wid = $1, $2
          guard(sid, wid) || handle_events_api(env, sid, wid)
        when "/sessions/bulk_delete"
          post_only(method) || handle_bulk_delete(env)
        when %r{\A/sessions/([^/]+)\z}
          sid = $1
          # The delete branch keys off delete_request? (DELETE, or POST with
          # ?_method=delete), so the id guard nests inside the method dispatch
          # rather than using the get_only/post_only combinators.
          if method == "GET"
            guard(sid) || handle_session_redirect(env, sid)
          elsif delete_request?(method, env)
            guard(sid) || handle_delete(env, sid)
          else
            not_found
          end
        when "/maintenance"
          get_only(method) || handle_maintenance(env)
        when %r{\A/custom-events(?:/.*)?\z}
          Sentiero::Web::MonitoringApp.new.call(env)
        when %r{\A/issues(?:/.*)?\z}
          Sentiero::Web::MonitoringApp.new.call(env)
        when %r{\A/analytics(?:/.*)?\z}
          Sentiero::Web::AnalyticsApp.new.call(env)
        else
          not_found
        end
      end

      private

      def handle_recorder_alias
        filename = Manifest.manifest["recorder"]
        return not_found unless filename

        status, headers, body = handle_asset(filename)
        # The alias serves new bundle contents after an upgrade, so it must not
        # inherit the fingerprinted file's year-long immutable cache.
        headers["cache-control"] = "public, max-age=300" if status == 200
        [status, headers, body]
      end

      def qs_url(path, env)
        qs = env["QUERY_STRING"]
        (qs && !qs.empty?) ? "#{path}?#{qs}" : path
      end

      def handle_index(env)
        params = query_params(env)
        page, per_page, offset = paginate(params, default: 20, max: 100)

        since, until_time = parse_range_params(params)
        sort_by = %w[updated_at created_at event_count].include?(params["sort_by"]) ? params["sort_by"] : nil
        search = params["search"]&.strip
        search = nil if search&.empty?
        has_errors_filter = params["has_errors"] == "true"

        sessions = fetch_sessions(
          has_errors_filter: has_errors_filter,
          per_page: per_page,
          offset: offset,
          since: since,
          until_time: until_time,
          sort_by: sort_by,
          search: search
        )

        sessions, has_next = take_page(sessions, per_page)

        audit!(env, action: :list_sessions)

        render_page(env, Views::SessionsIndexView.new(
          sessions: sessions,
          page: page,
          per_page: per_page,
          has_next: has_next,
          search: search || "",
          sort_by: sort_by || "updated_at",
          since: params["since"] || "",
          until_param: params["until"] || "",
          has_errors: has_errors_filter
        ))
      end

      def fetch_sessions(has_errors_filter:, per_page:, offset:, since:, until_time:, sort_by:, search:)
        unless has_errors_filter
          return Sentiero.store.list_sessions(
            limit: per_page + 1,
            offset: offset,
            since: since,
            until_time: until_time,
            sort_by: sort_by,
            search: search
          )
        end

        # The store has no has_errors index, so filter compute-on-read: scan up to
        # analytics_max_scan_sessions matching sessions, then slice the requested
        # page. Very large session counts make this a full scan.
        scan_cap = Sentiero.store.limits.analytics_max_scan_sessions
        all_matching = Sentiero.store.list_sessions(
          limit: scan_cap,
          offset: 0,
          since: since,
          until_time: until_time,
          sort_by: sort_by,
          search: search
        ).select { |s| s[:metadata] && s[:metadata]["has_errors"] }

        all_matching.slice(offset, per_page + 1) || []
      end

      def handle_session_redirect(env, session_id)
        session = Sentiero.store.get_session(session_id)
        return [404, {"content-type" => "text/plain"}, ["Session not found"]] unless session

        windows = session[:windows] || []
        return [404, {"content-type" => "text/plain"}, ["No windows found"]] if windows.empty?

        best = windows.max_by { |w| w[:last_event_at] || 0 }
        redirect("#{base_path(env)}/sessions/#{session_id}/windows/#{best[:window_id]}")
      end

      def handle_show(env, session_id, window_id)
        session = Sentiero.store.get_session(session_id)
        return [404, {"content-type" => "text/plain"}, ["Session not found"]] unless session

        audit!(env, action: :view_session, session_id: session_id, window_id: window_id)

        occ = Sentiero.store.occurrences_for_session(session_id, limit: 100)
        evs = Sentiero.store.server_events_for_session(session_id, limit: 100)
        server_activity = (
          occ.map { |o| {kind: "exception", timestamp: o["timestamp"].to_f, occurrence: o} } +
          evs.map { |e| {kind: "event", timestamp: e["timestamp"].to_f, event: e} }
        ).sort_by { |item| -item[:timestamp] }

        render_page(env, Views::SessionShowView.new(
          session: session,
          session_id: session_id,
          window_id: window_id,
          shareable_replays: Sentiero.configuration.shareable_replays,
          server_activity: server_activity
        ))
      end

      def handle_events_api(env, session_id, window_id)
        params = query_params(env)
        after = params["after"]
        limit = Sentiero.configuration.max_events_per_page

        events = Sentiero.store.get_events(Sentiero::WindowRef.new(session_id, window_id), after: after, limit: limit)

        audit!(env, action: :view_session, session_id: session_id, window_id: window_id)

        [200, json_headers, [JSON.generate(events)]]
      end

      def handle_delete(env, session_id)
        verify_csrf(env) || begin
          audit!(env, action: :delete_session, session_id: session_id)
          Sentiero.store.delete_session(session_id)
          redirect("#{base_path(env)}/")
        end
      end

      def handle_delete_window(env, session_id, window_id)
        verify_csrf(env) || begin
          audit!(env, action: :delete_session, session_id: session_id, window_id: window_id)
          Sentiero.store.delete_window(Sentiero::WindowRef.new(session_id, window_id))

          # Deleting the last window removes the session
          session = Sentiero.store.get_session(session_id)
          if session && session[:windows] && !session[:windows].empty?
            best = session[:windows].max_by { |w| w[:last_event_at] || 0 }
            redirect("#{base_path(env)}/sessions/#{session_id}/windows/#{best[:window_id]}")
          else
            redirect("#{base_path(env)}/")
          end
        end
      end

      def handle_bulk_delete(env)
        verify_csrf(env) || begin
          Array(Rack::Request.new(env).POST["session_ids"]).each do |sid|
            next unless valid_id?(sid)

            audit!(env, action: :delete_session, session_id: sid)
            Sentiero.store.delete_session(sid)
          end
          redirect("#{base_path(env)}/")
        end
      end

      def handle_maintenance(env)
        params = query_params(env)
        purged = params["purged"]&.then { |v| v.match?(/\A\d+\z/) ? v.to_i : nil }
        render_page(env, Views::MaintenanceView.new(
          retention_period: Sentiero.configuration.retention_period,
          purged: purged,
          error: params["error"]
        ), request_path: "/maintenance")
      end
    end
  end
end
