# frozen_string_literal: true

module PromptBuilder
  # Configuration for the model's reasoning behavior.
  class ReasoningConfig
    # @return [String, nil] the reasoning effort level (e.g. "low", "medium", "high")
    attr_reader :effort

    # @return [String, nil] the summary mode (e.g. "auto", "concise", "detailed")
    attr_reader :summary

    # Create a new ReasoningConfig.
    #
    # @param effort [String, nil] the reasoning effort level
    # @param summary [String, nil] the summary mode
    def initialize(effort: nil, summary: nil)
      @effort = effort
      @summary = summary
    end

    class << self
      # Deserialize a ReasoningConfig from a Hash.
      #
      # @param hash [Hash] a Hash with string keys
      # @return [ReasoningConfig]
      def from_h(hash)
        new(effort: hash["effort"], summary: hash["summary"])
      end
    end

    # Serialize to a Hash with string keys. Nil values are omitted.
    #
    # @return [Hash]
    def to_h
      h = {}
      h["effort"] = @effort if @effort
      h["summary"] = @summary if @summary
      h
    end
  end
end
