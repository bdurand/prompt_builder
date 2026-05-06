# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents text output content in an assistant message.
    class OutputText < Base
      # @return [String] the text content
      attr_reader :text

      # @return [Array<Hash>] annotations on the text
      attr_reader :annotations

      # @return [Array<Hash>] token log probabilities for the text
      attr_reader :logprobs

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      # Create a new OutputText content object.
      #
      # @param text [String] the text content
      # @param annotations [Array<Hash>] annotations on the text
      # @param logprobs [Array<Hash>] token log probabilities on the text
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(text:, annotations: [], logprobs: [], **extra)
        @text = text&.to_s
        @annotations = PromptBuilder.jsonify(annotations)
        @logprobs = PromptBuilder.jsonify(logprobs)
        @extra = extra.transform_keys(&:to_s)
      end

      class << self
        # Deserialize an OutputText from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [OutputText]
        def from_h(hash)
          new(
            text: hash["text"],
            annotations: hash["annotations"] || [],
            logprobs: hash["logprobs"] || [],
            **hash.except("type", "text", "annotations", "logprobs").transform_keys(&:to_sym)
          )
        end
      end

      # Serialize to a Hash with string keys. Empty annotations are omitted.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "output_text", "text" => @text}
        h["annotations"] = @annotations unless @annotations.empty?
        h["logprobs"] = @logprobs unless @logprobs.empty?
        h = PromptBuilder.jsonify(@extra).merge(h) unless @extra.empty?
        h
      end
    end
  end
end
