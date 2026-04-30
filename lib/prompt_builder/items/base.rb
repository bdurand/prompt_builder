# frozen_string_literal: true

module PromptBuilder
  module Items
    # Base class for conversation items. Provides polymorphic deserialization
    # via the +type+ field in the hash representation.
    class Base
      # Item type registry for polymorphic dispatch.
      TYPES = {
        "compaction" => "Compaction",
        "function_call" => "FunctionCall",
        "function_call_output" => "FunctionCallOutput",
        "item_reference" => "ItemReference",
        "message" => "Message",
        "reasoning" => "Reasoning"
      }.freeze

      class << self
        # Deserialize an item from a Hash by dispatching on the +type+ field.
        #
        # @param hash [Hash] a Hash with string keys including a +"type"+ field
        # @return [Items::Base] the deserialized item
        # @raise [InvalidItemError] if the type is unknown
        def from_h(hash)
          type = hash["type"]
          class_name = TYPES[type]
          raise InvalidItemError, "Unknown item type: #{type.inspect}" unless class_name

          Items.const_get(class_name).from_h(hash)
        end
      end

      # Serialize the item to a Hash with string keys.
      #
      # @return [Hash] the hash representation
      def to_h
        raise NotImplementedError
      end
    end
  end
end
