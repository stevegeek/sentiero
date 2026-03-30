# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sentiero::SessionMetadata do
  it "stores geo_location, user_agent, and referrer" do
    geo = Sentiero::GeoLocation.new(country_code: "US")
    metadata = described_class.new(
      geo_location: geo,
      user_agent: "Mozilla/5.0",
      referrer: "https://example.com"
    )

    expect(metadata.geo_location).to eq(geo)
    expect(metadata.user_agent).to eq("Mozilla/5.0")
    expect(metadata.referrer).to eq("https://example.com")
    expect(metadata.started_at).to be_a(Time)
  end

  describe "#to_h" do
    it "serializes with compact geo_location" do
      geo = Sentiero::GeoLocation.new(country_code: "US", city: nil)
      metadata = described_class.new(geo_location: geo, user_agent: "Bot/1.0")

      hash = metadata.to_h

      expect(hash[:geo_location]).to eq({ country_code: "US" })
      expect(hash[:user_agent]).to eq("Bot/1.0")
      expect(hash[:started_at]).to be_a(String)
      expect(hash).not_to have_key(:referrer)
    end

    it "omits geo_location when nil" do
      metadata = described_class.new

      expect(metadata.to_h).not_to have_key(:geo_location)
    end
  end
end
