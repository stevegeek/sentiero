# frozen_string_literal: true

require "rack/utils"

module Sentiero
  module Web
    # Shared HTTP Basic credential checking. Constant-time comparison;
    # assumes TLS terminated upstream.
    module BasicAuthCheck
      module_function

      def credentials_blank?(creds)
        creds[:user].to_s.empty? || creds[:password].to_s.empty?
      end

      def authorized?(env, creds)
        return false if credentials_blank?(creds)

        header = env["HTTP_AUTHORIZATION"]
        return false unless header

        scheme, encoded = header.split(" ", 2)
        return false unless scheme&.downcase == "basic" && encoded

        begin
          # Strict base64 decode: "m0" raises ArgumentError on invalid input.
          decoded = encoded.unpack1("m0")
        rescue ArgumentError
          return false
        end

        user, password = decoded.split(":", 2)
        return false if user.nil? || password.nil?

        user_ok = Rack::Utils.secure_compare(user, creds[:user].to_s)
        pass_ok = Rack::Utils.secure_compare(password, creds[:password].to_s)
        user_ok && pass_ok
      end
    end
  end
end
