# frozen_string_literal: true

require_relative "window_ref"
require_relative "store/limits"
require_relative "store/session_store"
require_relative "store/error_store"

module Sentiero
  # Abstract store contract, split across two mixins: SessionStore
  # (session-replay recording) and ErrorStore (error tracking). Concrete
  # backends subclass Store and implement both halves.
  class Store
    VALID_ID = /\A[a-zA-Z0-9_-]{1,128}\z/
    MAX_METADATA_KEYS = 50
    MAX_METADATA_VALUE_SIZE = 1024
    VALID_STATUS = %w[open resolved ignored].freeze
    PROBLEM_TITLE_MAX = 200

    include SessionStore
    include ErrorStore

    attr_writer :limits

    # Caps for eviction/scans. Defaults to Limits::DEFAULTS (static, not the
    # global config); pass limits: Limits.from_configuration to bind it, or
    # inject any other Limits to decouple a store from global state.
    def limits
      @limits ||= Limits.new
    end

    private

    def validate_id!(id)
      raise ArgumentError, "Invalid ID: #{id.inspect}" unless VALID_ID.match?(id.to_s)
    end

    def validate_window_ref!(ref)
      validate_id!(ref.session_id)
      validate_id!(ref.window_id)
    end

    def validate_metadata!(metadata)
      raise ArgumentError, "metadata must be a Hash" unless metadata.is_a?(Hash)
      metadata.each do |key, value|
        raise ArgumentError, "metadata key too long" if key.to_s.length > 128
        raise ArgumentError, "metadata value too large" if value.to_s.length > MAX_METADATA_VALUE_SIZE
      end
      raise ArgumentError, "too many metadata keys" if metadata.size > MAX_METADATA_KEYS
    end

    def validate_status!(status)
      raise ArgumentError, "Invalid status: #{status.inspect}" unless VALID_STATUS.include?(status)
    end

    def validate_occurrence!(occurrence)
      raise ArgumentError, "occurrence must be a Hash" unless occurrence.is_a?(Hash)
      %w[fingerprint project exception_class message timestamp].each do |key|
        raise ArgumentError, "occurrence missing #{key}" if occurrence[key].nil?
      end
      validate_id!(occurrence["fingerprint"])
      validate_id!(occurrence["project"])
    end

    def validate_server_event!(event)
      raise ArgumentError, "server event must be a Hash" unless event.is_a?(Hash)
      %w[project name timestamp].each do |key|
        raise ArgumentError, "server event missing #{key}" if event[key].nil?
      end
      validate_id!(event["project"])
    end
  end
end
