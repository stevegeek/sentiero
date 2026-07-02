# frozen_string_literal: true

require "ipaddr"

module Sentiero
  # Truncates client IPs before they reach a store or log when
  # +config.anonymize_ip+ is on. Standard practice for GDPR/CCPA "reasonable"
  # anonymization: zero the last IPv4 octet (/24) and the last 80 IPv6 bits
  # (/48). IPv4-mapped IPv6 collapses to its anonymized dotted-quad form.
  #
  # Anonymization is one-way and best-effort, not a re-identification guarantee.
  module IpAnonymizer
    module_function

    def anonymize(ip)
      return unless ip.is_a?(String)

      stripped = ip.strip
      return if stripped.empty?
      return if stripped.include?("/") # a client IP is a bare host, not a CIDR

      addr = IPAddr.new(stripped)
      addr = addr.native if addr.ipv4_mapped?
      addr.mask(addr.ipv4? ? 24 : 48).to_s
    rescue IPAddr::Error
      nil
    end
  end
end
