# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents reasoning text content from the model.
    class ReasoningText < Base
      # @return [String] the reasoning text content
      attr_reader :text

      # Create a new ReasoningText content object.
      #
      # @param text [String] the reasoning text content
      def initialize(text:)
        @text = text
      end

      class << self
        # Deserialize a ReasoningText from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [ReasoningText]
        def from_h(hash)
          new(text: hash["text"])
        end
      end

      # Serialize to a Hash with string keys.
      #
      # @return [Hash]
      def to_h
        {"type" => "reasoning_text", "text" => @text}
      end
    end

    Base.register_type("reasoning_text", ReasoningText)
  end
end
