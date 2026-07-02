# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "json"

module Sentiero
  module Web
    # Drives AssetsApp#call directly — the endpoint the Roda plugin mounts via
    # r.sentiero_assets. Until the A7 consolidation this copy of the asset
    # server was untested: the dashboard's /assets/* cases in security_test.rb
    # protected only BaseApp#handle_asset. These mirror those cases so the
    # (now shared) traversal protection and cache policy are pinned for both
    # entry points.
    class AssetsAppTest < Minitest::Test
      include Rack::Test::Methods

      def app
        AssetsApp.new
      end

      # A real fingerprinted asset name (name-HASH.ext), resolved through the
      # committed manifest so the test survives frontend rebuilds.
      def fingerprinted_asset
        manifest = JSON.parse(::File.read(::File.join(BaseApp::ASSETS_DIR, "manifest.json")))
        manifest.fetch("dashboard")
      end

      # ── Happy paths and cache policy ──

      def test_fingerprinted_asset_served_with_immutable_cache
        get "/#{fingerprinted_asset}"

        assert_equal 200, last_response.status
        assert_equal "application/javascript", last_response.headers["content-type"]
        assert_equal "public, max-age=31536000, immutable", last_response.headers["cache-control"]
      end

      def test_unfingerprinted_asset_served_with_daily_cache
        get "/manifest.json"

        assert_equal 200, last_response.status
        assert_equal "public, max-age=86400", last_response.headers["cache-control"]
      end

      # ── Method discipline ──

      def test_non_get_method_returns_405
        post "/#{fingerprinted_asset}"

        assert_equal 405, last_response.status
        assert_includes last_response.body, "Method Not Allowed"
      end

      # ── 404 family ──

      def test_empty_path_returns_404
        get "/"

        assert_equal 404, last_response.status
      end

      def test_missing_file_returns_404
        get "/nonexistent.css"

        assert_equal 404, last_response.status
      end

      def test_erb_template_returns_404
        get "/dashboard.html.erb"

        assert_equal 404, last_response.status,
          "ERB templates must not be served as static assets"
      end

      def test_erb_template_via_traversal_returns_404
        get "/../templates/dashboard.html.erb"

        assert_equal 404, last_response.status,
          "templates outside the asset dir must not be reachable"
      end

      def test_directory_returns_404
        get "/."

        assert_equal 404, last_response.status
      end

      # ── Traversal protection ──

      def test_parent_directory_traversal_blocked
        get "/../../etc/passwd"

        assert_equal 404, last_response.status
      end

      def test_absolute_path_blocked
        get "//etc/passwd"

        assert_equal 404, last_response.status
      end
    end
  end
end
