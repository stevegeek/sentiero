# frozen_string_literal: true

require_relative "normalizer"

module Sentiero
  module Reporter
    # Immutable, string-keyed bag of report context. Keys are normalized to
    # strings on construction and on every merge.
    class Context
      def initialize(hash = {})
        @data = Normalizer.stringify_shallow(hash).freeze
      end

      def merge(other)
        Context.new(@data.merge(Normalizer.stringify_shallow(to_hash(other))))
      end

      def [](key) = @data[key.to_s]

      def key?(key) = @data.key?(key.to_s)

      def empty? = @data.empty?

      def to_h = @data.dup

      private

      def to_hash(other) = other.is_a?(Context) ? other.to_h : other
    end
  end
end
