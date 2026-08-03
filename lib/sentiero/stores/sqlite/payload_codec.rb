# frozen_string_literal: true

require "zlib"

module Sentiero
  module Stores
    class SQLite
      # zlib compression for events.data payloads. FullSnapshots dominate the
      # table's bytes (~93% in production samples) and deflate ~6-7x, so
      # payloads at or above the threshold are stored as compressed BLOBs;
      # smaller rows stay plain JSON TEXT (near-zero win, and skipping them
      # keeps ~85% of rows out of the deflate path). Reads sniff the storage
      # format from the payload itself: a zlib stream starts with 0x78 and a
      # valid header checksum, which no JSON text can.
      module PayloadCodec
        COMPRESSION_THRESHOLD = 1024
        # CMF byte for deflate with a 32K window — the only one zlib emits.
        ZLIB_FIRST_BYTE = 0x78

        module_function

        def encode(json)
          return json if json.bytesize < COMPRESSION_THRESHOLD

          ::SQLite3::Blob.new(Zlib::Deflate.deflate(json))
        end

        def decode(data)
          return data unless compressed?(data)

          Zlib::Inflate.inflate(data).force_encoding(Encoding::UTF_8)
        end

        def compressed?(data)
          data.getbyte(0) == ZLIB_FIRST_BYTE &&
            (flg = data.getbyte(1)) &&
            (((ZLIB_FIRST_BYTE << 8) | flg) % 31).zero?
        end
      end
    end
  end
end
