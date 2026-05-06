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

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      # Create a new Compaction item.
      #
      # @param id [String, nil] the compaction item identifier
      # @param encrypted_content [String, nil] encrypted compacted content
      # @param created_by [String, nil] who created the compaction
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(id: nil, encrypted_content: nil, created_by: nil, **extra)
        @id = id&.to_s
        @encrypted_content = encrypted_content&.to_s
        @created_by = created_by&.to_s
        @extra = extra.transform_keys(&:to_s)
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
            created_by: hash["created_by"],
            **hash.except("type", "id", "encrypted_content", "created_by").transform_keys(&:to_sym)
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
        h = PromptBuilder.jsonify(@extra).merge(h) unless @extra.empty?
        h
      end
    end
  end
end
