# frozen_string_literal: true

require "json"

module Sentiero
  module Web
    module Manifest
      ASSETS_DIR = File.expand_path("assets", __dir__).freeze

      def self.manifest
        if @auto_reload
          load_manifest
        else
          @manifest ||= load_manifest
        end
      end

      # Re-read manifest from disk on every access (dev, for `npm run watch`).
      def self.auto_reload!
        @auto_reload = true
      end

      def self.asset_path(logical_name, base_path = "")
        filename = manifest[logical_name]
        unless filename
          raise Sentiero::Error, "Unknown asset: #{logical_name}. Run 'cd frontend && npm run build' first."
        end
        "#{base_path}/assets/#{filename}"
      end

      def self.reset!
        @manifest = load_manifest
        @auto_reload = false
      end

      private_class_method def self.load_manifest
        path = File.join(ASSETS_DIR, "manifest.json")
        return {}.freeze unless File.exist?(path)
        JSON.parse(File.read(path)).freeze
      end
    end
  end
end
