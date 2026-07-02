# frozen_string_literal: true

require_relative "base_app"
require_relative "../analytics/browser_event_discovery"
require_relative "../analytics/error_discovery"
require_relative "../analytics/server_event_metrics"
require_relative "../analytics/problem_detail"

module Sentiero
  module Web
    # Rack app owning the error/issue tracking (/issues/*) and custom-event
    # browsing (/custom-events/*) routes. Mounted at the same point as
    # DashboardApp (which delegates those requests here), so PATH_INFO/SCRIPT_NAME
    # are read from env to preserve base_path.
    class MonitoringApp < BaseApp
      def initialize
        super
        BaseApp.warn_unauthenticated_once
      end

      def call(env)
        path = env["PATH_INFO"] || "/"
        method = env["REQUEST_METHOD"]

        return unauthorized_response unless authorized?(env)

        case path
        when "/custom-events"
          handle_events_index(env)
        when %r{\A/custom-events/([^/]+)\z}
          event_id = $1
          get_only(method) || guard(event_id) || handle_event_show(env, event_id)
        when "/issues"
          handle_errors_index(env)
        when %r{\A/issues/client/([^/]+)\z}
          # Matched BEFORE the generic /issues/:id case so "client" isn't taken as
          # a server fingerprint. Client error ids are ErrorDiscovery group digests,
          # not store ids, so there is no id guard here.
          id = $1
          get_only(method) || handle_client_error_show(env, id)
        when %r{\A/issues/([^/]+)/status\z}
          problem_id = $1
          post_only(method) || guard(problem_id) || handle_error_status(env, problem_id)
        when %r{\A/issues/([^/]+)\z}
          problem_id = $1
          get_only(method) || guard(problem_id) || handle_error_show(env, problem_id)
        else
          not_found
        end
      end

      private

      def handle_event_show(env, event_id)
        event = Sentiero.store.get_server_event(event_id)
        return not_found if event.nil?

        audit!(env, action: :view_event)
        render_page(env, Views::EventShowView.new(event: event), csrf: false)
      end

      def handle_events_index(env)
        params = query_params(env)
        return handle_browser_events(env) if params["source"] == "browser"

        level = %w[debug info warn error].include?(params["level"]) ? params["level"] : nil
        search = params["search"]
        project_param = params["project"]
        project_param = nil if project_param&.empty?
        since, until_time = parse_range_params(params)
        since_param, until_param = echo_range_params(params, since, until_time)

        page, per_page, offset = paginate(params, default: 50, max: 200)

        events = filtered_server_events(level: level, project: project_param, search: search, since: since, until_time: until_time)
        page_events, has_next = take_page(events.slice(offset, per_page + 1) || [], per_page)

        audit!(env, action: :list_events)

        projects = (Sentiero.configuration.ingest_keys || {}).values.uniq.sort

        sibling = if events.empty? && level.nil? && search.to_s.empty? && project_param.nil? && since.nil? && until_time.nil?
          result = Sentiero::Analytics::BrowserEventDiscovery.new(Sentiero.store).recent_events
          {count: result[:rows].size, capped: result[:was_truncated]}
        end

        # level_mix and payload metrics compute over the full pre-pagination list,
        # so the strips describe the whole filtered range, not one page.
        metrics = Sentiero::Analytics::ServerEventMetrics.new(events)
        render_page(env, Views::EventsIndexView.new(
          events: page_events,
          level: level || "",
          search: search || "",
          project: project_param || "",
          projects: projects,
          since_param: since_param,
          until_param: until_param,
          level_mix: metrics.level_mix_by_day,
          page: page,
          per_page: per_page,
          has_next: has_next,
          sibling: sibling,
          **metrics.payload_metric_locals(params["metric_key"])
        ), csrf: false)
      end

      # Bounded server-event fetch for the events index, request filters applied.
      # `since` rides the store's after: param (strict >, equivalent for a midnight
      # bound); `until` and name search filter in Ruby. Newest first for display.
      def filtered_server_events(level:, project:, search:, since:, until_time:)
        events = Sentiero.store.list_server_events(project: project, limit: 10_000, level: level, after: since)
        events = events.select { |e| e["timestamp"].to_f <= until_time } if until_time
        if search && !search.empty?
          term = search.downcase
          events = events.select { |e| e["name"].to_s.downcase.include?(term) }
        end
        events.reverse
      end

      # Bound on the store-list calls behind sibling-tab counts in empty states;
      # a count that hits the cap renders as "500+".
      SIBLING_COUNT_LIMIT = 500

      def handle_browser_events(env)
        params = query_params(env)
        search = params["search"]
        since, until_time = parse_range_params(params)
        since_param, until_param = echo_range_params(params, since, until_time)

        page, per_page, offset = paginate(params, default: 50, max: 200)

        result = Sentiero::Analytics::BrowserEventDiscovery.new(Sentiero.store)
          .recent_events(since: since, until_time: until_time)
        rows = result[:rows]
        if search && !search.empty?
          term = search.downcase
          rows = rows.select { |r| r[:name].to_s.downcase.include?(term) }
        end
        page_rows, has_next = take_page(rows.slice(offset, per_page + 1) || [], per_page)

        # Bounded count of the sibling server-events tab for the empty-state cross-link.
        sibling = if rows.empty? && search.to_s.empty? && since.nil? && until_time.nil?
          server_events = Sentiero.store.list_server_events(project: nil, limit: SIBLING_COUNT_LIMIT)
          {count: server_events.size, capped: server_events.size >= SIBLING_COUNT_LIMIT}
        end

        audit!(env, action: :list_events)
        render_page(env, Views::EventsIndexView.new(
          source: "browser",
          browser_rows: page_rows,
          search: search || "",
          since_param: since_param,
          until_param: until_param,
          page: page,
          per_page: per_page,
          has_next: has_next,
          was_truncated: result[:was_truncated],
          sibling: sibling,
          **Sentiero::Analytics::ServerEventMetrics.new(
            Sentiero::Analytics::ServerEventMetrics.adapt_browser_rows(rows)
          ).payload_metric_locals(params["metric_key"])
        ), csrf: false)
      end

      # Unified errors listing. `?source=client` renders aggregated client-side JS
      # errors; otherwise the server-exception ("problems") listing. The server
      # branch sets the CSRF cookie for inline resolve/ignore.
      def handle_errors_index(env)
        params = query_params(env)
        source = (params["source"] == "client") ? "client" : "server"
        if source == "client"
          handle_client_errors_index(env, params)
        else
          handle_server_errors_index(env, params)
        end
      end

      def handle_server_errors_index(env, params)
        status = %w[open resolved ignored].include?(params["status"]) ? params["status"] : nil
        search = params["search"]
        sort_by = %w[last_seen first_seen count].include?(params["sort_by"]) ? params["sort_by"] : "last_seen"
        since, until_time = parse_range_params(params)
        since_param, until_param = echo_range_params(params, since, until_time)

        page, per_page, offset = paginate(params, default: 50, max: 200)
        problems = Sentiero.store.list_problems(project: nil, limit: per_page + 1, offset: offset,
          status: status, sort_by: sort_by, search: search, since: since, until_time: until_time)
        problems, has_next = take_page(problems, per_page)

        audit!(env, action: :list_problems)

        sibling = if problems.empty? && page == 1 && status.nil? && search.to_s.empty? && since.nil? && until_time.nil?
          result = Sentiero::Analytics::ErrorDiscovery.new(Sentiero.store).grouped_errors
          {count: result[:groups].size, capped: result[:was_truncated]}
        end

        render_page(env, Views::ErrorsIndexView.new(
          source: "server",
          problems: problems,
          sibling: sibling,
          status: status || "",
          search: search || "",
          sort_by: sort_by,
          since_param: since_param,
          until_param: until_param,
          new_since: since,
          page: page,
          per_page: per_page,
          has_next: has_next
        ))
      end

      def handle_client_errors_index(env, params)
        sort_by = %w[count recency].include?(params["sort_by"]) ? params["sort_by"] : "count"
        search = params["search"]
        since, until_time = parse_range_params(params)
        since_param, until_param = echo_range_params(params, since, until_time)

        page, per_page, offset = paginate(params, default: 50, max: 200)

        result = Sentiero::Analytics::ErrorDiscovery.new(Sentiero.store)
          .grouped_errors(sort_by: sort_by, since: since, until_time: until_time)
        groups = result[:groups]
        if search && !search.empty?
          term = search.downcase
          groups = groups.select { |g| g[:message].to_s.downcase.include?(term) }
        end
        page_groups, has_next = take_page(groups.slice(offset, per_page + 1) || [], per_page)

        audit!(env, action: :list_problems)

        # Bounded count of the sibling server-exceptions tab for the empty-state cross-link.
        sibling = if groups.empty? && search.to_s.empty? && since.nil? && until_time.nil?
          problems = Sentiero.store.list_problems(project: nil, limit: SIBLING_COUNT_LIMIT)
          {count: problems.size, capped: problems.size >= SIBLING_COUNT_LIMIT}
        end

        render_page(env, Views::ErrorsIndexView.new(
          source: "client",
          groups: page_groups,
          sibling: sibling,
          sort_by: sort_by,
          search: search || "",
          since_param: since_param,
          until_param: until_param,
          page: page,
          per_page: per_page,
          has_next: has_next,
          was_truncated: result[:was_truncated]
        ))
      end

      # Client-side JS error detail page. Re-runs ErrorDiscovery and finds the
      # group whose stable :id matches.
      def handle_client_error_show(env, id)
        result = Sentiero::Analytics::ErrorDiscovery.new(Sentiero.store).grouped_errors
        group = result[:groups].find { |g| g[:id] == id }
        return not_found if group.nil?

        audit!(env, action: :view_client_error)

        render_page(env, Views::ClientErrorShowView.new(group: group, was_truncated: result[:was_truncated]), csrf: false)
      end

      def handle_error_show(env, problem_id)
        problem = Sentiero.store.get_problem(problem_id)
        return not_found if problem.nil?

        occurrences = Sentiero.store.get_occurrences(problem_id, limit: 50).reverse # newest first
        session_ids = Sentiero.store.session_ids_for_problem(problem_id, limit: 50)

        session_summaries = session_ids.map do |sid|
          session = Sentiero.store.get_session(sid)
          if session
            first_window = (session[:windows] || []).first
            ua = session.dig(:metadata, "userAgent")
            {
              session_id: sid,
              first_event_at: session[:first_event_at],
              last_event_at: session[:last_event_at],
              browser: ua ? parse_browser(ua) : nil,
              window_id: first_window ? first_window[:window_id] : nil
            }
          else
            {session_id: sid, first_event_at: nil, last_event_at: nil, browser: nil, window_id: nil}
          end
        end

        audit!(env, action: :view_problem, problem_id: problem_id)

        detail = Sentiero::Analytics::ProblemDetail.new(Sentiero.store)
        render_page(env, Views::ProblemShowView.new(
          problem: problem,
          occurrences: occurrences,
          session_ids: session_ids,
          session_summaries: session_summaries,
          facets: detail.facets(occurrences, session_summaries),
          trend: detail.trend(problem_id, occurrences)
        ))
      end

      def handle_error_status(env, problem_id)
        request = Rack::Request.new(env)
        return forbidden_csrf unless valid_csrf_token?(env, request.POST["csrf_token"])

        status = request.POST["status"]
        return [400, {"content-type" => "text/plain"}, ["bad status"]] unless %w[open resolved ignored].include?(status)

        Sentiero.store.update_problem_status(problem_id, status)
        audit!(env, action: :update_problem_status, problem_id: problem_id)

        redirect("#{base_path(env)}/issues/#{problem_id}", status: 303)
      end
    end
  end
end
