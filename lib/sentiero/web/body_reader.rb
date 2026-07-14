# frozen_string_literal: true

require "stringio"
require "zlib"

module Sentiero
  module Web
    # Reads a request body (optionally gzip-encoded) with a hard 512KB cap on
    # BOTH the compressed and decompressed size, so a gzip bomb can't blow past
    # it. Shared by the two untrusted-input lanes (EventsApp, IngestApp), which
    # differ only in the response they build from the error symbol.
    module BodyReader
      MAX_BODY_SIZE = 524_288 # 512 KB

      # error symbol => [http_status, message]
      ERRORS = {
        too_large: [413, "request body too large"],
        bad_gzip: [400, "invalid gzip encoding"]
      }.freeze

      module_function

      # [body, nil] on success, or [nil, :too_large | :bad_gzip] on failure.
      def read(env)
        raw = env["rack.input"].read(MAX_BODY_SIZE + 1) || ""
        env["rack.input"].rewind if env["rack.input"].respond_to?(:rewind)
        return [nil, :too_large] if raw.bytesize > MAX_BODY_SIZE

        if gzip?(env, raw)
          begin
            gz = Zlib::GzipReader.new(StringIO.new(raw))
            raw = gz.read(MAX_BODY_SIZE + 1) || ""
            gz.close
          rescue Zlib::GzipFile::Error
            return [nil, :bad_gzip]
          end
          return [nil, :too_large] if raw.bytesize > MAX_BODY_SIZE
        end

        [raw, nil]
      end

      # Decompress when the client declared gzip or the body starts with the
      # gzip magic number. The magic-byte path lets unload beacons ship
      # compressed as text/plain without a Content-Encoding header, which would
      # otherwise force a CORS preflight sendBeacon can't perform. JSON never
      # begins with these bytes, so detection is unambiguous.
      def gzip?(env, raw)
        env["HTTP_CONTENT_ENCODING"]&.downcase == "gzip" ||
          (raw.getbyte(0) == 0x1f && raw.getbyte(1) == 0x8b)
      end
    end
  end
end
