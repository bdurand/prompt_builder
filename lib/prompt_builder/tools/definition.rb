# frozen_string_literal: true

module PromptBuilder
  module Tools
    # Represents a tool definition that describes a function available to the model.
    class Definition
      # @return [String] the tool name
      attr_reader :name

      # @return [String, nil] the tool description
      attr_reader :description

      # @return [Hash, nil] the JSON Schema for the tool parameters
      attr_reader :parameters

      # @return [Boolean] whether strict mode is enabled
      attr_reader :strict

      # Create a new tool Definition.
      #
      # @param name [String] the tool name
      # @param description [String, nil] the tool description
      # @param parameters [Hash, nil] the JSON Schema for the parameters
      # @param strict [Boolean] whether strict mode is enabled
      def initialize(name:, description: nil, parameters: nil, strict: false)
        @name = name&.to_s
        @description = description&.to_s
        @parameters = PromptBuilder.jsonify(parameters)
        @strict = strict ? true : false
      end

      class << self
        # Deserialize a Definition from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [Definition]
        def from_h(hash)
          new(
            name: hash["name"],
            description: hash["description"],
            parameters: hash["parameters"],
            strict: hash.fetch("strict", false)
          )
        end
      end

      # Serialize to a Hash with string keys. Nil values are omitted.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "function", "name" => @name}
        h["description"] = @description if @description
        h["parameters"] = @parameters if @parameters
        h["strict"] = @strict if @strict
        h
      end
    end
  end
end
