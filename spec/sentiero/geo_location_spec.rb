# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sentiero::GeoLocation do
  it "stores geo fields via keyword arguments" do
    geo = described_class.new(country_code: "US", city: "San Francisco", latitude: 37.77)

    expect(geo.country_code).to eq("US")
    expect(geo.city).to eq("San Francisco")
    expect(geo.latitude).to eq(37.77)
  end

  describe "#to_h" do
    it "strips nil fields" do
      geo = described_class.new(country_code: "DE", city: nil)

      expect(geo.to_h).to eq({ country_code: "DE" })
    end

    it "includes all populated fields" do
      geo = described_class.new(
        country_code: "US",
        city: "Portland",
        region: "Oregon",
        region_code: "OR",
        postal_code: "97201",
        timezone: "America/Los_Angeles",
        latitude: 45.52,
        longitude: -122.68,
        ip: "203.0.113.1"
      )

      expect(geo.to_h).to eq({
        country_code: "US",
        city: "Portland",
        region: "Oregon",
        region_code: "OR",
        postal_code: "97201",
        timezone: "America/Los_Angeles",
        latitude: 45.52,
        longitude: -122.68,
        ip: "203.0.113.1"
      })
    end
  end
end
