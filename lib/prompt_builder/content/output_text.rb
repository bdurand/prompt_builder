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

      # Create a new OutputText content object.
      #
      # @param text [String] the text content
      # @param annotations [Array<Hash>] annotations on the text
      # @param logprobs [Array<Hash>] token log probabilities on the text
      def initialize(text:, annotations: [], logprobs: [])
        @text = text
        @annotations = annotations
        @logprobs = logprobs
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
            logprobs: hash["logprobs"] || []
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
        h
      end
    end

    Base.register_type("output_text", OutputText)
  end
end
