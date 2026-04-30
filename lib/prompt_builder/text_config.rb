# frozen_string_literal: true

module PromptBuilder
  # Configuration for the model's text output format.
  class TextConfig
    # @return [Hash, nil] the format configuration
    attr_reader :format

    # @return [String, nil] the verbosity configuration
    attr_reader :verbosity

    # Create a new TextConfig.
    #
    # @param format [Hash, nil] the format configuration
    # @param verbosity [String, nil] the verbosity configuration
    def initialize(format: nil, verbosity: nil)
      @format = PromptBuilder.jsonify(format)
      @verbosity = verbosity&.to_s
    end

    class << self
      # Deserialize a TextConfig from a Hash.
      #
      # @param hash [Hash] a Hash with string keys
      # @return [TextConfig]
      def from_h(hash)
        new(format: hash["format"], verbosity: hash["verbosity"])
      end
    end

    # Serialize to a Hash with string keys. Nil values are omitted.
    #
    # @return [Hash]
    def to_h
      h = {}
      h["format"] = @format if @format
      h["verbosity"] = @verbosity if @verbosity
      h
    end
  end
end
