# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents generic text content in a message or reasoning item.
    class Text < Base
      # @return [String] the text content
      attr_reader :text

      # Create a new Text content object.
      #
      # @param text [String] the text content
      def initialize(text:)
        @text = text
      end

      class << self
        # Deserialize a Text from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [Text]
        def from_h(hash)
          new(text: hash["text"])
        end
      end

      # Serialize to a Hash with string keys.
      #
      # @return [Hash]
      def to_h
        {"type" => "text", "text" => @text}
      end
    end

    Base.register_type("text", Text)
  end
end
