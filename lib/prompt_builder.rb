# frozen_string_literal: true

require_relative "prompt_builder/errors"

# Top-level module for the PromptBuilder gem. Provides a DSL for constructing
# Open Responses API request payloads and parsing responses.
module PromptBuilder
  autoload :Content, "prompt_builder/content"
  autoload :Items, "prompt_builder/items"
  autoload :Response, "prompt_builder/response"
  autoload :Session, "prompt_builder/session"
  autoload :ToolRegistry, "prompt_builder/tool_registry"
  autoload :Usage, "prompt_builder/usage"
  autoload :Serializers, "prompt_builder/serializers"
  autoload :Tools, "prompt_builder/tools"

  VERSION = File.read(File.join(__dir__, "../VERSION")).strip

  class << self
    # Convert a value to a JSON-safe structure by deep-stringifying Hash keys
    # and converting Symbols to Strings.
    #
    # @param value [Object] the value to convert
    # @return [Object] the JSON-safe value
    def jsonify(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), h| h[k.to_s] = jsonify(v) }
      when Array
        value.map { |v| jsonify(v) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    # Returns the global tool registry singleton.
    #
    # @return [ToolRegistry]
    def tool_registry
      @tool_registry ||= ToolRegistry.new
    end

    # Register a tool in the global registry.
    #
    # @param name [String] the tool name
    # @param description [String, nil] the tool description
    # @param parameters [Hash, nil] the JSON Schema for parameters
    # @param strict [Boolean] whether strict mode is enabled
    # @yield [Hash] the parsed arguments when the tool is invoked
    # @yieldreturn [Object] the tool output (String, Hash, Array, or any object)
    # @return [Tools::Definition] the registered definition
    def register_tool(name, description: nil, parameters: nil, strict: false, &handler)
      tool_registry.register(name, description: description, parameters: parameters, strict: strict, &handler)
    end

    # Reset the global tool registry. Primarily used in tests.
    #
    # @return [void]
    def reset_tool_registry!
      @tool_registry = ToolRegistry.new
    end
  end
end
