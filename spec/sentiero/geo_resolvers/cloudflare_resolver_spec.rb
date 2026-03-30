# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sentiero::GeoResolvers::CloudflareResolver do
  subject(:resolver) { described_class.new }

  def rack_request(env = {})
    Rack::Request.new(Rack::MockRequest.env_for("/", env))
  end

  context "with all Cloudflare headers present" do
    let(:request) do
      rack_request(
        "HTTP_CF_IPCOUNTRY" => "US",
        "HTTP_CF_IPCITY" => "San Francisco",
        "HTTP_CF_REGION" => "California",
        "HTTP_CF_REGION_CODE" => "CA",
        "HTTP_CF_POSTAL_CODE" => "94107",
        "HTTP_CF_TIMEZONE" => "America/Los_Angeles",
        "HTTP_CF_IPLATITUDE" => "37.7749",
        "HTTP_CF_IPLONGITUDE" => "-122.4194",
        "HTTP_CF_CONNECTING_IP" => "203.0.113.1"
      )
    end

    it "returns a GeoLocation with all fields populated" do
      geo = resolver.resolve(request)

      expect(geo).to be_a(Sentiero::GeoLocation)
      expect(geo.country_code).to eq("US")
      expect(geo.city).to eq("San Francisco")
      expect(geo.region).to eq("California")
      expect(geo.region_code).to eq("CA")
      expect(geo.postal_code).to eq("94107")
      expect(geo.timezone).to eq("America/Los_Angeles")
      expect(geo.latitude).to eq(37.7749)
      expect(geo.longitude).to eq(-122.4194)
      expect(geo.ip).to eq("203.0.113.1")
    end

    it "casts latitude and longitude to Float" do
      geo = resolver.resolve(request)

      expect(geo.latitude).to be_a(Float)
      expect(geo.longitude).to be_a(Float)
    end
  end

  context "with only country header (free Cloudflare plan)" do
    let(:request) do
      rack_request("HTTP_CF_IPCOUNTRY" => "DE")
    end

    it "returns a GeoLocation with only country_code" do
      geo = resolver.resolve(request)

      expect(geo.country_code).to eq("DE")
      expect(geo.city).to be_nil
      expect(geo.latitude).to be_nil
    end
  end

  context "with no Cloudflare headers" do
    let(:request) { rack_request }

    it "returns nil" do
      expect(resolver.resolve(request)).to be_nil
    end
  end

  context "when capture_ip is disabled" do
    before do
      Sentiero.configure { |c| c.capture_ip = false }
    end

    let(:request) do
      rack_request(
        "HTTP_CF_IPCOUNTRY" => "US",
        "HTTP_CF_CONNECTING_IP" => "203.0.113.1"
      )
    end

    it "does not include IP in the result" do
      geo = resolver.resolve(request)

      expect(geo.country_code).to eq("US")
      expect(geo.ip).to be_nil
    end
  end
end
