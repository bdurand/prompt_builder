# frozen_string_literal: true

require "json"

module PromptBuilder
  module Items
    # Represents a function call item in a conversation. This is output
    # by the model when it wants to invoke a tool.
    class FunctionCall < Base
      # @return [String] the function name
      attr_reader :name

      # @return [String] the unique call identifier
      attr_reader :call_id

      # @return [String] the JSON-encoded arguments string
      attr_reader :arguments

      # @return [String, nil] the item identifier
      attr_reader :id

      # @return [String, nil] the call status
      attr_reader :status

      # Create a new FunctionCall item.
      #
      # @param name [String] the function name
      # @param call_id [String] the unique call identifier
      # @param arguments [String] the JSON-encoded arguments string
      # @param id [String, nil] the item identifier
      # @param status [String, nil] the call status
      def initialize(name:, call_id:, arguments:, id: nil, status: nil)
        @name = name&.to_s
        @call_id = call_id&.to_s
        @arguments = arguments&.to_s
        @id = id&.to_s
        @status = status&.to_s
      end

      class << self
        # Deserialize a FunctionCall from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [FunctionCall]
        def from_h(hash)
          new(
            name: hash["name"],
            call_id: hash["call_id"],
            arguments: hash["arguments"],
            id: hash["id"],
            status: hash["status"]
          )
        end
      end

      # Parse the JSON arguments string into a Hash.
      #
      # @raise [PromptBuilder::InvalidItemError] if the arguments string is not valid JSON
      # @return [Hash] the parsed arguments
      def parsed_arguments
        JSON.parse(@arguments)
      rescue JSON::ParserError => e
        raise PromptBuilder::InvalidItemError, "Invalid JSON in function call arguments for '#{@name}': #{e.message}"
      end

      # Serialize to a Hash with string keys. Nil values are omitted.
      #
      # @return [Hash]
      def to_h
        h = {
          "type" => "function_call",
          "name" => @name,
          "call_id" => @call_id,
          "arguments" => @arguments
        }
        h["id"] = @id if @id
        h["status"] = @status if @status
        h
      end
    end
  end
end
