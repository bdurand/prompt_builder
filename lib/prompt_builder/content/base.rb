# frozen_string_literal: true

module PromptBuilder
  module Content
    # Base class for content objects. Provides polymorphic deserialization
    # via the +type+ field in the hash representation.
    class Base
      # Content type registry for polymorphic dispatch.
      TYPES = {}

      class << self
        # Deserialize a content object from a Hash by dispatching on the +type+ field.
        #
        # @param hash [Hash] a Hash with string keys including a +"type"+ field
        # @return [Content::Base] the deserialized content object
        # @raise [InvalidItemError] if the type is unknown
        def from_h(hash)
          type = hash["type"]
          klass = TYPES[type]
          raise InvalidItemError, "Unknown content type: #{type.inspect}" unless klass

          klass.from_h(hash)
        end

        # Register a content subclass for a given type string.
        #
        # @param type [String] the type identifier
        # @param klass [Class] the content class to register
        # @return [void]
        def register_type(type, klass)
          TYPES[type] = klass
        end
      end

      # Serialize the content object to a Hash with string keys.
      #
      # @return [Hash] the hash representation
      def to_h
        raise NotImplementedError
      end
    end
  end
end
