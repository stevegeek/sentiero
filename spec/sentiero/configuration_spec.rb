# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sentiero::Configuration do
  describe "defaults" do
    it "uses cloudflare as the default geo resolver" do
      expect(subject.geo_resolver).to eq(:cloudflare)
    end

    it "captures IP by default" do
      expect(subject.capture_ip).to be true
    end

    it "has no maxmind database path" do
      expect(subject.maxmind_database_path).to be_nil
    end
  end

  describe "#build_resolver" do
    it "builds a CloudflareResolver for :cloudflare" do
      subject.geo_resolver = :cloudflare

      expect(subject.build_resolver).to be_a(Sentiero::GeoResolvers::CloudflareResolver)
    end

    it "returns nil for :none" do
      subject.geo_resolver = :none

      expect(subject.build_resolver).to be_nil
    end

    it "returns a custom resolver as-is" do
      custom = Object.new
      def custom.resolve(_request); end

      subject.geo_resolver = custom

      expect(subject.build_resolver).to equal(custom)
    end
  end

  describe "Sentiero.configure" do
    it "yields the configuration" do
      Sentiero.configure do |config|
        config.capture_ip = false
      end

      expect(Sentiero.configuration.capture_ip).to be false
    end
  end
end
