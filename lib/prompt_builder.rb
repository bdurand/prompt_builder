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

    # Construct a base64-encoded data URL from raw binary data and a content type.
    #
    # @param data [String] the raw binary data
    # @param content_type [String] the MIME content type (e.g. "image/png", "application/pdf")
    # @return [String] a data URL in the form "data:<content_type>;base64,<encoded_data>"
    def data_url(data, content_type)
      "data:#{content_type};base64,#{[data].pack("m0")}"
    end

    # Parse a data URL into its media type and base64-encoded data. Media type
    # parameters (e.g. "data:text/plain;charset=utf-8;base64,...") are allowed
    # and excluded from the returned media type.
    #
    # @param url [String, nil] a URL that may be a data URL
    # @return [Array(String, String), nil] a two-element array of +[media_type, data]+
    #   or nil if the URL is not a base64-encoded data URL
    def parse_data_url(url)
      return nil unless url
      match = url.match(/\Adata:([^;,]+)(?:;[^,]*)?;base64,(.*)\z/m)
      return nil unless match
      [match[1], match[2]]
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
