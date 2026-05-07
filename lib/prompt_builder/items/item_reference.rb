# frozen_string_literal: true

module PromptBuilder
  module Items
    # Represents a reference to an existing conversation item by ID.
    class ItemReference < Base
      # @return [String] the referenced item identifier
      attr_reader :id

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      # Create a new ItemReference item.
      #
      # @param id [String] the referenced item identifier
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(id:, **extra)
        @id = id&.to_s
        @extra = extra.transform_keys(&:to_s)
      end

      class << self
        # Deserialize an ItemReference from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [ItemReference]
        def from_h(hash)
          new(id: hash["id"], **hash.except("type", "id").transform_keys(&:to_sym))
        end
      end

      # Serialize to a Hash with string keys.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "item_reference", "id" => @id}
        h = PromptBuilder.jsonify(@extra).merge(h) unless @extra.empty?
        h
      end
    end
  end
end
