# frozen_string_literal: true

module PromptBuilder
  module Content
    # Base class for content objects. Provides polymorphic deserialization
    # via the +type+ field in the hash representation.
    class Base
      # Content type registry for polymorphic dispatch.
      TYPES = {
        "input_file" => "InputFile",
        "input_image" => "InputImage",
        "input_text" => "InputText",
        "input_video" => "InputVideo",
        "output_text" => "OutputText",
        "reasoning_text" => "ReasoningText",
        "refusal" => "RefusalContent",
        "summary_text" => "SummaryText",
        "text" => "Text"
      }.freeze

      class << self
        # Deserialize a content object from a Hash by dispatching on the +type+ field.
        #
        # @param hash [Hash] a Hash with string keys including a +"type"+ field
        # @return [Content::Base] the deserialized content object
        # @raise [InvalidItemError] if the type is unknown
        def from_h(hash)
          type = hash["type"]
          class_name = TYPES[type]
          raise InvalidItemError, "Unknown content type: #{type.inspect}" unless class_name

          Content.const_get(class_name).from_h(hash)
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
