# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents reasoning text content from the model.
    class ReasoningText < Base
      # @return [String] the reasoning text content
      attr_reader :text

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      # Create a new ReasoningText content object.
      #
      # @param text [String] the reasoning text content
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(text:, **extra)
        @text = text&.to_s
        @extra = extra.transform_keys(&:to_s)
      end

      class << self
        # Deserialize a ReasoningText from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [ReasoningText]
        def from_h(hash)
          new(text: hash["text"], **hash.except("type", "text").transform_keys(&:to_sym))
        end
      end

      # Serialize to a Hash with string keys.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "reasoning_text", "text" => @text}
        h = PromptBuilder.jsonify(@extra).merge(h) unless @extra.empty?
        h
      end
    end
  end
end
