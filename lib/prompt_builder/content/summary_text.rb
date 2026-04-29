# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents a summary text content from the model's reasoning.
    class SummaryText < Base
      # @return [String] the summary text content
      attr_reader :text

      # Create a new SummaryText content object.
      #
      # @param text [String] the summary text content
      def initialize(text:)
        @text = text
      end

      class << self
        # Deserialize a SummaryText from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [SummaryText]
        def from_h(hash)
          new(text: hash["text"])
        end
      end

      # Serialize to a Hash with string keys.
      #
      # @return [Hash]
      def to_h
        {"type" => "summary_text", "text" => @text}
      end
    end

    Base.register_type("summary_text", SummaryText)
  end
end
