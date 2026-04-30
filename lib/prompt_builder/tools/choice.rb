# frozen_string_literal: true

module PromptBuilder
  module Tools
    # Represents a tool choice configuration that controls how the model
    # selects tools. Can be a simple string value ("auto", "required", "none")
    # or a specific function reference.
    class Choice
      # @return [String, Hash] the raw choice value
      attr_reader :value

      # Create a new tool Choice.
      #
      # @param value [String, Hash] the choice value
      def initialize(value:)
        @value = PromptBuilder.jsonify(value)
      end

      class << self
        # Deserialize a Choice from a raw value.
        #
        # @param value [String, Hash] the raw choice value
        # @return [Choice]
        def from_h(value)
          new(value: value)
        end
      end

      # Check if this is an auto choice.
      #
      # @return [Boolean]
      def auto?
        @value == "auto"
      end

      # Check if this is a required choice.
      #
      # @return [Boolean]
      def required?
        @value == "required"
      end

      # Check if this is a none choice.
      #
      # @return [Boolean]
      def none?
        @value == "none"
      end

      # Check if this is a specific function choice.
      #
      # @return [Boolean]
      def specific_function?
        @value.is_a?(Hash) && @value["type"] == "function"
      end

      # Check if this is an allowed_tools choice.
      #
      # @return [Boolean]
      def allowed_tools?
        @value.is_a?(Hash) && @value["type"] == "allowed_tools"
      end

      # Get the function name for a specific function choice.
      #
      # @return [String, nil] the function name, or nil if not a specific function choice
      def function_name
        return nil unless specific_function?

        @value["name"]
      end

      # Get the list of allowed tool names for an allowed_tools choice.
      #
      # @return [Array<String>, nil] the allowed tool names, or nil if not an allowed_tools choice
      def allowed_tools
        return nil unless allowed_tools?

        @value["tools"]
      end

      # Get the mode for an allowed_tools choice.
      #
      # @return [String, nil] the mode value (e.g. "auto"), or nil if not set
      def mode
        return nil unless @value.is_a?(Hash)

        @value["mode"]
      end

      # Serialize to the raw value.
      #
      # @return [String, Hash]
      def to_h
        @value
      end
    end
  end
end
