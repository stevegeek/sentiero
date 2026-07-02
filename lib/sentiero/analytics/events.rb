# frozen_string_literal: true

module Sentiero
  module Analytics
    # rrweb protocol constants shared by analyzers.
    module Events
      # rrweb EventType.IncrementalSnapshot
      INCREMENTAL = 3
      # rrweb EventType.Meta
      META = 4
      # rrweb EventType.Custom
      CUSTOM = 5
      # rrweb IncrementalSource.MouseInteraction
      SOURCE_MOUSE_INTERACTION = 2
      # rrweb IncrementalSource.Scroll
      SOURCE_SCROLL = 3
      # rrweb IncrementalSource.Input
      SOURCE_INPUT = 5
    end
  end
end
