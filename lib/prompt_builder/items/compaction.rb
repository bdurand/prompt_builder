# frozen_string_literal: true

module PromptBuilder
  module Items
    # Represents a compaction item that summarizes earlier conversation history.
    class Compaction < Base
      # @return [String, nil] the compaction item identifier
      attr_reader :id

      # @return [String, nil] encrypted compacted content
      attr_reader :encrypted_content

      # @return [String, nil] who created the compaction (e.g. "user" or "assistant")
      attr_reader :created_by

      # Create a new Compaction item.
      #
      # @param id [String, nil] the compaction item identifier
      # @param encrypted_content [String, nil] encrypted compacted content
      # @param created_by [String, nil] who created the compaction
      def initialize(id: nil, encrypted_content: nil, created_by: nil)
        @id = id
        @encrypted_content = encrypted_content
        @created_by = created_by
      end

      class << self
        # Deserialize a Compaction item from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [Compaction]
        def from_h(hash)
          new(
            id: hash["id"],
            encrypted_content: hash["encrypted_content"],
            created_by: hash["created_by"]
          )
        end
      end

      # Serialize to a Hash with string keys. Nil values are omitted.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "compaction"}
        h["id"] = @id if @id
        h["encrypted_content"] = @encrypted_content if @encrypted_content
        h["created_by"] = @created_by if @created_by
        h
      end
    end

    Base.register_type("compaction", Compaction)
  end
end
