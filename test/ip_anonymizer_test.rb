# frozen_string_literal: true

require "test_helper"

class IpAnonymizerTest < Minitest::Test
  def anonymize(ip) = Sentiero::IpAnonymizer.anonymize(ip)

  # IPv4: zero the last octet (/24)
  def test_ipv4_zeros_last_octet
    assert_equal "1.2.3.0", anonymize("1.2.3.4")
  end

  def test_ipv4_all_zeros_unchanged
    assert_equal "0.0.0.0", anonymize("0.0.0.0")
  end

  def test_ipv4_broadcast
    assert_equal "255.255.255.0", anonymize("255.255.255.255")
  end

  def test_ipv4_private_address
    assert_equal "192.168.1.0", anonymize("192.168.1.42")
  end

  def test_ipv4_already_anonymized_is_idempotent
    assert_equal "10.0.0.0", anonymize(anonymize("10.0.0.99"))
  end

  # IPv6: zero the last 80 bits (/48)
  def test_ipv6_zeros_last_80_bits
    assert_equal "2001:db8::", anonymize("2001:db8::1")
  end

  def test_ipv6_full_address
    assert_equal "2001:db8:abcd::", anonymize("2001:db8:abcd:1234:5678:9abc:def0:1234")
  end

  def test_ipv6_loopback
    assert_equal "::", anonymize("::1")
  end

  def test_ipv6_keeps_first_48_bits
    assert_equal "fe80:1:2::", anonymize("fe80:0001:0002:0003:0004:0005:0006:0007")
  end

  # IPv4-mapped IPv6 collapses to an anonymized dotted-quad IPv4.
  def test_ipv4_mapped_ipv6_returns_anonymized_ipv4
    assert_equal "1.2.3.0", anonymize("::ffff:1.2.3.4")
  end

  # Malformed / unusable input returns nil.
  def test_nil_returns_nil
    assert_nil anonymize(nil)
  end

  def test_empty_string_returns_nil
    assert_nil anonymize("")
  end

  def test_blank_string_returns_nil
    assert_nil anonymize("   ")
  end

  def test_junk_returns_nil
    assert_nil anonymize("not an ip")
  end

  def test_incomplete_ipv4_returns_nil
    assert_nil anonymize("192.168.1")
  end

  def test_out_of_range_octet_returns_nil
    assert_nil anonymize("999.1.1.1")
  end

  def test_malformed_ipv6_returns_nil
    assert_nil anonymize("gggg::")
  end

  def test_non_string_returns_nil
    assert_nil anonymize(1234)
    assert_nil anonymize(["1.2.3.4"])
  end

  # A bare host value is expected; a CIDR/prefixed value is not a client IP.
  def test_cidr_input_returns_nil
    assert_nil anonymize("1.2.3.4/24")
  end

  # Surrounding whitespace is tolerated.
  def test_trims_whitespace
    assert_equal "1.2.3.0", anonymize("  1.2.3.4  ")
  end
end
