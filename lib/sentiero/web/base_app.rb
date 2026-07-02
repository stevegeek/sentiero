# frozen_string_literal: true

require "json"
require "securerandom"
require "uri"
require "time"
require_relative "escaping"
require_relative "formatting"
require_relative "views"
require_relative "basic_auth_check"
require_relative "../store"
require_relative "../user_agent"
require_relative "../ip_anonymizer"

module Sentiero
  module Web
    # Shared, non-routing machinery for the dashboard UI Rack apps (DashboardApp,
    # AnalyticsApp, MonitoringApp): auth, CSRF, escaping, security headers, asset
    # serving, the routing combinators, and the render_page view-rendering entry
    # point. Subclasses implement their own #call routing.
    class BaseApp
      include Escaping
      include Formatting

      ASSETS_DIR = File.expand_path("assets", __dir__).freeze

      CSP_POLICY = [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "frame-src 'self' blob:"
      ].join("; ").freeze

      CONTENT_TYPES = {
        ".css" => "text/css",
        ".js" => "application/javascript",
        ".html" => "text/html",
        ".png" => "image/png",
        ".svg" => "image/svg+xml"
      }.freeze

      # Warn at most once per process: the Roda plugin and /analytics delegation
      # construct apps per request, so a per-construction warning would spam.
      AUTH_WARNING_LOCK = Mutex.new
      @auth_warning_emitted = false

      class << self
        # With no auth configured the dashboard fails closed (403) unless
        # allow_insecure_dashboard is set, in which case it serves unauthenticated
        # and we warn once. Called on BaseApp so both subclasses share one flag
        # (class ivars aren't inherited).
        def warn_unauthenticated_once
          config = Sentiero.configuration
          return if config.basic_auth || config.auth_callback
          return unless config.allow_insecure_dashboard

          AUTH_WARNING_LOCK.synchronize do
            return if @auth_warning_emitted
            @auth_warning_emitted = true
          end

          warn "[Sentiero] dashboard mounted with allow_insecure_dashboard and no " \
            "authentication (config.basic_auth and config.auth_callback both unset); " \
            "session recordings and analytics are publicly accessible to anyone who " \
            "can reach this mount. Set config.basic_auth or config.auth_callback to " \
            "protect it."
        end

        def reset_auth_warning!
          @auth_warning_emitted = false
        end
      end

      private

      def authorized?(env)
        creds = Sentiero.configuration.basic_auth
        return basic_auth_authorized?(env, creds) unless creds.nil?

        callback = Sentiero.configuration.auth_callback
        # No auth configured: fail closed unless explicitly opted out.
        return Sentiero.configuration.allow_insecure_dashboard if callback.nil?
        !!callback.call(env)
      rescue Sentiero::Error
        raise
      rescue => e
        warn "[Sentiero] auth_callback raised #{e.class}: #{e.message}"
        false
      end

      def basic_auth_authorized?(env, creds)
        if BasicAuthCheck.credentials_blank?(creds)
          raise Sentiero::Error,
            "config.basic_auth is set but the username or password is blank. " \
            "Set SENTIERO_DASHBOARD_PASSWORD (or remove config.basic_auth to " \
            "disable dashboard auth)."
        end
        BasicAuthCheck.authorized?(env, creds)
      end

      def audit!(env, action:, session_id: nil, window_id: nil, dataset: nil, problem_id: nil)
        callback = Sentiero.configuration.audit_log
        return if callback.nil?

        callback.call(
          action: action,
          session_id: session_id,
          window_id: window_id,
          dataset: dataset,
          problem_id: problem_id,
          user: audit_user(env),
          ip: audit_ip(env),
          timestamp: Time.now,
          path: env["PATH_INFO"]
        )
      rescue => e
        warn "[Sentiero] audit_log raised #{e.class}: #{e.message}"
      end

      def audit_user(env)
        env["sentiero.user"] || env["REMOTE_USER"]
      end

      def audit_ip(env)
        forwarded = env["HTTP_X_FORWARDED_FOR"]&.split(",")&.first&.strip
        ip = (forwarded && !forwarded.empty?) ? forwarded : env["REMOTE_ADDR"]
        Sentiero.configuration.anonymize_ip ? IpAnonymizer.anonymize(ip) : ip
      end

      def forbidden
        [403, {"content-type" => "text/plain"}, ["Forbidden"]]
      end

      def unauthorized_response
        if Sentiero.configuration.basic_auth.nil?
          forbidden
        else
          [401,
            {"content-type" => "text/plain", "www-authenticate" => 'Basic realm="Sentiero"'},
            ["Unauthorized"]]
        end
      end

      def not_found
        [404, {"content-type" => "text/plain"}, ["Not Found"]]
      end

      def redirect(location, status: 302)
        [status, {"location" => location}, []]
      end

      # Mount prefix (empty for a root mount); prepended to redirect targets.
      def base_path(env)
        env["SCRIPT_NAME"] || ""
      end

      def invalid_id
        [400, json_headers, ['{"error":"invalid ID format"}']]
      end

      def forbidden_csrf
        [403, {"content-type" => "text/plain"}, ["Invalid CSRF token"]]
      end

      # Combinator: returns a 403 to short-circuit a mutating route when the CSRF
      # token is missing/invalid, or nil to fall through (`verify_csrf(env) || …`).
      def verify_csrf(env)
        forbidden_csrf unless valid_csrf_token?(env, Rack::Request.new(env).POST["csrf_token"])
      end

      def valid_id?(id)
        id.is_a?(String) && id.match?(Store::VALID_ID)
      end

      def html_headers(extra = {})
        {
          "content-type" => "text/html",
          "content-security-policy" => CSP_POLICY,
          "x-content-type-options" => "nosniff",
          "x-frame-options" => "DENY"
        }.merge(extra)
      end

      def json_headers(extra = {})
        {"content-type" => "application/json", "x-content-type-options" => "nosniff"}.merge(extra)
      end

      def generate_csrf_token
        SecureRandom.hex(32)
      end

      def csrf_cookie_header(env, csrf_token, base_path)
        cookie = "sentiero_csrf=#{csrf_token}; HttpOnly; SameSite=Strict; Path=#{base_path}/"
        cookie += "; Secure" if env["rack.url_scheme"] == "https"
        cookie
      end

      def valid_csrf_token?(env, token)
        expected = Rack::Utils.parse_cookies(env)["sentiero_csrf"]
        return false if expected.nil? || expected.empty?
        return false if token.nil? || token.empty?
        Rack::Utils.secure_compare(expected, token)
      end

      # Standard `since`/`until` range params (ISO date or ISO-8601 timestamp),
      # parsed in UTC. Zone-less timestamps assume UTC; invalid input = no filter.
      DATE_ONLY_FORMAT = /\A\d{4}-\d{2}-\d{2}\z/
      END_OF_DAY_SECONDS = 86_399.999

      def parse_range_params(params)
        [parse_since_param(params["since"]), parse_until_param(params["until"])]
      end

      def parse_since_param(value)
        parse_utc_time_param(value, end_of_day: false)
      end

      def parse_until_param(value)
        parse_utc_time_param(value, end_of_day: true)
      end

      def parse_utc_time_param(value, end_of_day:)
        return nil if value.nil? || value.empty?

        if DATE_ONLY_FORMAT.match?(value)
          base = Time.utc(*value.split("-").map(&:to_i)).to_f
          end_of_day ? base + END_OF_DAY_SECONDS : base
        elsif value.match?(/(?:Z|[+-]\d{2}:?\d{2})\z/i)
          Time.parse(value).to_f
        else
          Time.parse("#{value} UTC").to_f
        end
      rescue ArgumentError, TypeError, RangeError
        nil
      end

      def echo_range_params(params, since, until_time)
        [since ? params["since"].to_s : "", until_time ? params["until"].to_s : ""]
      end

      # Ceiling on the requested page
      MAX_PAGE = 10_000

      def clamp_page(value)
        page = value.to_i
        page = 1 if page < 1
        [page, MAX_PAGE].min
      end

      def clamp_per_page(value, default:, max:)
        per_page = value.to_i
        per_page = default if per_page < 1
        [per_page, max].min
      end

      def query_params(env)
        Rack::Utils.parse_query(env["QUERY_STRING"] || "")
      end

      # Clamped [page, per_page, offset] from the request params.
      def paginate(params, default:, max:)
        page = clamp_page(params["page"])
        per_page = clamp_per_page(params["per_page"], default: default, max: max)
        [page, per_page, (page - 1) * per_page]
      end

      # Callers obtain per_page + 1 rows; the extra row signals that another page exists
      def take_page(rows, per_page)
        [rows.first(per_page), rows.size > per_page]
      end

      # Router combinators: each returns an early-exit Rack response, or nil to
      # fall through, so a route arm reads
      # `get_only(method) || guard(id) || handle_x(env, id)`.

      def get_only(method)
        not_found unless method == "GET"
      end

      def post_only(method)
        not_found unless method == "POST"
      end

      # 400 unless every captured path id is well-formed, so malformed ids are
      # rejected before they reach a handler or a store query.
      def guard(*ids)
        invalid_id unless ids.all? { |id| valid_id?(id) }
      end

      def delete_request?(method, env)
        return true if method == "DELETE"

        method == "POST" && query_params(env)["_method"] == "delete"
      end

      def handle_asset(relative_path)
        require_relative "assets_app"
        AssetsApp.new.serve(relative_path)
      end

      # With csrf: true a CSRF token is minted, set as the sentiero_csrf cookie,
      # and injected into the view as csrf_token.
      def render_page(env, view, csrf: true, request_path: nil)
        view.base_path = base_path(env)
        request_path ||= env["PATH_INFO"] || "/"
        headers = if csrf
          token = generate_csrf_token
          view.csrf_token = token
          html_headers("set-cookie" => csrf_cookie_header(env, token, view.base_path))
        else
          html_headers
        end
        body = view.render_layout(view.render, request_path: request_path)
        [200, headers, [body]]
      end
    end
  end
end
