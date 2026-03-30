# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Sentiero::Middleware::GeoCapture do
  let(:inner_app) do
    lambda do |env|
      geo = env[described_class::ENV_GEO_KEY]
      metadata = env[described_class::ENV_METADATA_KEY]

      body = {
        geo: geo&.to_h,
        metadata: metadata&.to_h
      }.to_json

      [200, { "content-type" => "application/json" }, [body]]
    end
  end

  let(:app) { described_class.new(inner_app) }

  def get(path = "/", env = {})
    status, headers, body = app.call(Rack::MockRequest.env_for(path, env))
    JSON.parse(body.first, symbolize_names: true)
  end

  context "with Cloudflare headers" do
    it "populates geo_location and session_metadata in the env" do
      result = get("/", {
        "HTTP_CF_IPCOUNTRY" => "US",
        "HTTP_CF_IPCITY" => "San Francisco",
        "HTTP_CF_CONNECTING_IP" => "203.0.113.1",
        "HTTP_USER_AGENT" => "TestBrowser/1.0",
        "HTTP_REFERER" => "https://example.com"
      })

      expect(result[:geo][:country_code]).to eq("US")
      expect(result[:geo][:city]).to eq("San Francisco")
      expect(result[:geo][:ip]).to eq("203.0.113.1")
      expect(result[:metadata][:user_agent]).to eq("TestBrowser/1.0")
      expect(result[:metadata][:referrer]).to eq("https://example.com")
      expect(result[:metadata][:geo_location][:country_code]).to eq("US")
    end
  end

  context "without Cloudflare headers" do
    it "sets geo to nil and still populates metadata" do
      result = get("/", { "HTTP_USER_AGENT" => "TestBrowser/1.0" })

      expect(result[:geo]).to be_nil
      expect(result[:metadata][:user_agent]).to eq("TestBrowser/1.0")
      expect(result[:metadata]).not_to have_key(:geo_location)
    end
  end

  context "with resolver set to :none" do
    before do
      Sentiero.configure { |c| c.geo_resolver = :none }
    end

    let(:app) { described_class.new(inner_app) }

    it "skips geo resolution" do
      result = get("/", { "HTTP_CF_IPCOUNTRY" => "US" })

      expect(result[:geo]).to be_nil
    end
  end
end
