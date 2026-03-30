# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sentiero::GeoFilter do
  let(:sessions) do
    [
      { geo_location: { country_code: "US", city: "San Francisco", region: "California", timezone: "America/Los_Angeles", latitude: 37.77, longitude: -122.42 } },
      { geo_location: { country_code: "US", city: "Portland", region: "Oregon", timezone: "America/Los_Angeles", latitude: 45.52, longitude: -122.68 } },
      { geo_location: { country_code: "DE", city: "Berlin", region: "Berlin", timezone: "Europe/Berlin", latitude: 52.52, longitude: 13.40 } },
      { geo_location: { country_code: "DE", city: "Munich", region: "Bavaria", timezone: "Europe/Berlin", latitude: 48.14, longitude: 11.58 } },
      { geo_location: nil }
    ]
  end

  describe ".by_country" do
    it "filters by country code" do
      result = described_class.by_country(sessions, "US")

      expect(result.length).to eq(2)
      expect(result.map { |s| s.dig(:geo_location, :city) }).to contain_exactly("San Francisco", "Portland")
    end

    it "returns empty for unknown country" do
      expect(described_class.by_country(sessions, "JP")).to be_empty
    end
  end

  describe ".by_city" do
    it "filters by city name" do
      result = described_class.by_city(sessions, "Berlin")

      expect(result.length).to eq(1)
      expect(result.first.dig(:geo_location, :country_code)).to eq("DE")
    end
  end

  describe ".by_region" do
    it "filters by region" do
      result = described_class.by_region(sessions, "California")

      expect(result.length).to eq(1)
    end
  end

  describe ".by_timezone" do
    it "filters by timezone" do
      result = described_class.by_timezone(sessions, "Europe/Berlin")

      expect(result.length).to eq(2)
    end
  end

  describe ".within_radius" do
    it "finds sessions within a radius" do
      # San Francisco to Portland is ~860km. Use 900km radius from SF.
      result = described_class.within_radius(sessions, lat: 37.77, lng: -122.42, radius_km: 900)

      expect(result.length).to eq(2)
      expect(result.map { |s| s.dig(:geo_location, :city) }).to contain_exactly("San Francisco", "Portland")
    end

    it "excludes sessions outside the radius" do
      # 10km radius from SF center — should only match SF
      result = described_class.within_radius(sessions, lat: 37.77, lng: -122.42, radius_km: 10)

      expect(result.length).to eq(1)
      expect(result.first.dig(:geo_location, :city)).to eq("San Francisco")
    end

    it "skips sessions without coordinates" do
      result = described_class.within_radius(sessions, lat: 0, lng: 0, radius_km: 100_000)

      # The nil geo_location session should be excluded
      expect(result.length).to eq(4)
    end
  end
end
