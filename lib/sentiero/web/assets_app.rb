# frozen_string_literal: true

require_relative "base_app"

module Sentiero
  module Web
    # Standalone Rack endpoint serving the gem's static assets (mounted via
    # r.sentiero_assets). Shares #serve with BaseApp#handle_asset so the dashboard's
    # /assets/* route applies the same traversal guard, content types, and caching.
    class AssetsApp < BaseApp
      def call(env)
        return [405, {"content-type" => "text/plain"}, ["Method Not Allowed"]] unless env["REQUEST_METHOD"] == "GET"

        serve(env["PATH_INFO"].delete_prefix("/"))
      end

      # Resolved path must stay inside ASSETS_DIR (blocks traversal/absolute
      # paths); .erb files are never served raw. Fingerprinted basenames
      # (name-HASH.ext) get a year of immutable cache (31536000s), else one day.
      def serve(relative_path)
        return not_found if relative_path.nil? || relative_path.empty?

        full_path = File.expand_path(relative_path, ASSETS_DIR)

        return not_found unless full_path.start_with?(ASSETS_DIR + File::SEPARATOR)
        return not_found if full_path.end_with?(".erb")
        return not_found unless File.file?(full_path)

        ext = File.extname(full_path)
        content_type = CONTENT_TYPES.fetch(ext, "application/octet-stream")

        cache_control = if File.basename(full_path).match?(/\A[^\/]+-[A-Za-z0-9]+\.\w+\z/)
          "public, max-age=31536000, immutable"
        else
          "public, max-age=86400"
        end

        [200, {"content-type" => content_type, "cache-control" => cache_control}, [File.binread(full_path)]]
      end
    end
  end
end
