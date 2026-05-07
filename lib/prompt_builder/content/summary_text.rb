# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents a summary text content from the model's reasoning.
    class SummaryText < Base
      # @return [String] the summary text content
      attr_reader :text

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      # Create a new SummaryText content object.
      #
      # @param text [String] the summary text content
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(text:, **extra)
        @text = text&.to_s
        @extra = extra.transform_keys(&:to_s)
      end

      class << self
        # Deserialize a SummaryText from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [SummaryText]
        def from_h(hash)
          new(text: hash["text"], **hash.except("type", "text").transform_keys(&:to_sym))
        end
      end

      # Serialize to a Hash with string keys.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "summary_text", "text" => @text}
        h = PromptBuilder.jsonify(@extra).merge(h) unless @extra.empty?
        h
      end
    end
  end
end
