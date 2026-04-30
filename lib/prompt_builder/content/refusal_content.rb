# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents a refusal content block returned by the model.
    class RefusalContent < Base
      # @return [String] the refusal message
      attr_reader :refusal

      # Create a new RefusalContent object.
      #
      # @param refusal [String] the refusal message
      def initialize(refusal:)
        @refusal = refusal&.to_s
      end

      class << self
        # Deserialize a RefusalContent from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [RefusalContent]
        def from_h(hash)
          new(refusal: hash["refusal"])
        end
      end

      # Serialize to a Hash with string keys.
      #
      # @return [Hash]
      def to_h
        {"type" => "refusal", "refusal" => @refusal}
      end
    end
  end
end
