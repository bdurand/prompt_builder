# frozen_string_literal: true

module PromptBuilder
  module Items
    # Base class for conversation items. Provides polymorphic deserialization
    # via the +type+ field in the hash representation.
    class Base
      # Item type registry for polymorphic dispatch.
      TYPES = {}

      class << self
        # Deserialize an item from a Hash by dispatching on the +type+ field.
        #
        # @param hash [Hash] a Hash with string keys including a +"type"+ field
        # @return [Items::Base] the deserialized item
        # @raise [InvalidItemError] if the type is unknown
        def from_h(hash)
          type = hash["type"]
          klass = TYPES[type]
          raise InvalidItemError, "Unknown item type: #{type.inspect}" unless klass

          klass.from_h(hash)
        end

        # Register an item subclass for a given type string.
        #
        # @param type [String] the type identifier
        # @param klass [Class] the item class to register
        # @return [void]
        def register_type(type, klass)
          TYPES[type] = klass
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
