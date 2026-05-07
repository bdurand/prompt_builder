# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents a refusal content block returned by the model.
    class RefusalContent < Base
      # @return [String] the refusal message
      attr_reader :refusal

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      # Create a new RefusalContent object.
      #
      # @param refusal [String] the refusal message
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(refusal:, **extra)
        @refusal = refusal&.to_s
        @extra = extra.transform_keys(&:to_s)
      end

      class << self
        # Deserialize a RefusalContent from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [RefusalContent]
        def from_h(hash)
          new(refusal: hash["refusal"], **hash.except("type", "refusal").transform_keys(&:to_sym))
        end
      end

      # Serialize to a Hash with string keys.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "refusal", "refusal" => @refusal}
        h = PromptBuilder.jsonify(@extra).merge(h) unless @extra.empty?
        h
      end
    end
  end
end
