# frozen_string_literal: true

module PromptBuilder
  # Registry for tool definitions and their handler callables.
  class ToolRegistry
    # Create a new ToolRegistry.
    def initialize
      @definitions = {}
      @handlers = {}
    end

    # Register a tool with its definition and handler.
    #
    # @param name [String] the tool name
    # @param description [String, nil] the tool description
    # @param parameters [Hash, nil] the JSON Schema for parameters
    # @param strict [Boolean] whether strict mode is enabled
    # @param callable [#call, nil] a callable handler (alternative to block)
    # @yield [Hash] the parsed arguments when the tool is invoked
    # @yieldreturn [String] the tool output
    # @return [Tools::Definition] the registered definition
    def register(name, description: nil, parameters: nil, strict: false, callable: nil, &handler)
      definition = Tools::Definition.new(
        name: name,
        description: description,
        parameters: parameters,
        strict: strict
      )
      @definitions[name] = definition
      @handlers[name] = callable || handler
      definition
    end

    # Look up a handler by name.
    #
    # @param name [String] the tool name
    # @return [#call, nil] the handler, or nil if not found
    def handler_for(name)
      @handlers[name]
    end

    # Look up a definition by name.
    #
    # @param name [String] the tool name
    # @return [Tools::Definition, nil] the definition, or nil if not found
    def definition_for(name)
      @definitions[name]
    end

    # Return all tool definitions.
    #
    # @return [Array<Tools::Definition>] all tool definitions
    def definitions
      @definitions.values
    end

    # Invoke a tool by name with the given arguments.
    #
    # @param name [String] the tool name
    # @param arguments [Hash] the parsed arguments
    # @return [String] the tool output
    # @raise [ToolNotFoundError] if no handler is found for the given name
    def invoke(name, arguments)
      handler = handler_for(name)
      raise ToolNotFoundError, "No handler registered for tool: #{name.inspect}" unless handler

      result = handler.call(arguments)
      result.to_s
    end
  end
end
