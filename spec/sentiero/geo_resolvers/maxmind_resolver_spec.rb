# frozen_string_literal: true

require "spec_helper"
require "sentiero/geo_resolvers/maxmind_resolver"

RSpec.describe Sentiero::GeoResolvers::MaxmindResolver do
  # Stub the MaxMind gem structure so tests work without the real gem
  before do
    stub_const("MaxMind::GeoIP2::Reader", Class.new {
      define_method(:initialize) { |database:| }
      define_method(:city) { |_ip| nil }
    })

    stub_const("MaxMind::GeoIP2::AddressNotFoundError", Class.new(StandardError))

    allow(Sentiero::GeoResolvers::MaxmindResolver).to receive(:require_maxmind!)
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with("/path/to/GeoLite2-City.mmdb").and_return(true)
  end

  let(:resolver) do
    described_class.new("/path/to/GeoLite2-City.mmdb")
  end

  def rack_request(ip: "203.0.113.1")
    env = Rack::MockRequest.env_for("/", "REMOTE_ADDR" => ip)
    Rack::Request.new(env)
  end

  context "with a successful lookup" do
    let(:mock_record) do
      country = double("country", iso_code: "US", name: "United States")
      city = double("city", name: "San Francisco")
      subdivision = double("subdivision", name: "California", iso_code: "CA")
      postal = double("postal", code: "94107")
      location = double("location",
        time_zone: "America/Los_Angeles",
        latitude: 37.7749,
        longitude: -122.4194
      )

      double("record",
        country: country,
        city: city,
        most_specific_subdivision: subdivision,
        postal: postal,
        location: location
      )
    end

    it "returns a GeoLocation with all fields" do
      allow_any_instance_of(MaxMind::GeoIP2::Reader).to receive(:city).and_return(mock_record)

      geo = resolver.resolve(rack_request)

      expect(geo).to be_a(Sentiero::GeoLocation)
      expect(geo.country_code).to eq("US")
      expect(geo.country_name).to eq("United States")
      expect(geo.city).to eq("San Francisco")
      expect(geo.region).to eq("California")
      expect(geo.region_code).to eq("CA")
      expect(geo.postal_code).to eq("94107")
      expect(geo.timezone).to eq("America/Los_Angeles")
      expect(geo.latitude).to eq(37.7749)
      expect(geo.longitude).to eq(-122.4194)
      expect(geo.ip).to eq("203.0.113.1")
    end
  end

  context "when address is not found" do
    it "returns nil" do
      allow_any_instance_of(MaxMind::GeoIP2::Reader)
        .to receive(:city)
        .and_raise(MaxMind::GeoIP2::AddressNotFoundError, "not found")

      expect(resolver.resolve(rack_request)).to be_nil
    end
  end

  context "when capture_ip is disabled" do
    let(:mock_record) do
      country = double("country", iso_code: "DE", name: "Germany")
      double("record",
        country: country,
        city: nil,
        most_specific_subdivision: nil,
        postal: nil,
        location: nil
      )
    end

    it "does not include IP" do
      Sentiero.configure { |c| c.capture_ip = false }
      allow_any_instance_of(MaxMind::GeoIP2::Reader).to receive(:city).and_return(mock_record)

      geo = resolver.resolve(rack_request)

      expect(geo.country_code).to eq("DE")
      expect(geo.ip).to be_nil
    end
  end

  context "when database path is missing" do
    it "raises an error" do
      expect {
        described_class.new(nil)
      }.to raise_error(Sentiero::Error, /database path is required/)
    end
  end
end
