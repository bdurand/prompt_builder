# frozen_string_literal: true

module PromptBuilder
  # The main DSL entry point for building Open Responses API request payloads.
  # Manages conversation items, tool registration, and serialization to
  # multiple API formats.
  class Session
    # Boolean fields that may legitimately be false; serialized with a nil? check.
    BOOLEAN_FIELDS = %i[parallel_tool_calls stream background store].freeze
    private_constant :BOOLEAN_FIELDS

    # String-typed fields coerced with .to_s on assignment.
    STRING_FIELDS = %i[
      model instructions previous_response_id truncation safety_identifier prompt_cache_key prompt_cache_retention service_tier
    ].freeze
    private_constant :STRING_FIELDS

    # Float-typed fields coerced with .to_f on assignment.
    FLOAT_FIELDS = %i[temperature top_p presence_penalty frequency_penalty].freeze
    private_constant :FLOAT_FIELDS

    # Integer-typed fields coerced with .to_i on assignment.
    INTEGER_FIELDS = %i[max_output_tokens max_tool_calls top_logprobs].freeze
    private_constant :INTEGER_FIELDS

    # Complex fields serialized to JSON-compatible values via PromptBuilder.jsonify.
    JSONIFY_FIELDS = %i[include tool_choice metadata text stream_options reasoning].freeze
    private_constant :JSONIFY_FIELDS

    # Effort levels accepted by +think+. This is the union of the levels
    # recognized across serializers; each serializer omits levels its target
    # API does not support.
    THINK_EFFORT_LEVELS = %w[minimal low medium high xhigh max].freeze
    private_constant :THINK_EFFORT_LEVELS

    # All keyword options accepted by +initialize+.
    INITIALIZE_OPTIONS = (
      STRING_FIELDS + FLOAT_FIELDS + INTEGER_FIELDS + BOOLEAN_FIELDS + JSONIFY_FIELDS + %i[input extra system]
    ).freeze

    # @!attribute [rw] model
    #   @return [String, nil] the model identifier
    # @!attribute [rw] instructions
    #   @return [String, nil] the system instructions
    # @!attribute [rw] previous_response_id
    #   @return [String, nil] the previous response identifier for server-side state
    # @!attribute [rw] truncation
    #   @return [String, nil] the truncation strategy
    # @!attribute [rw] safety_identifier
    #   @return [String, nil] the safety identifier
    # @!attribute [rw] prompt_cache_key
    #   @return [String, nil] the prompt cache key
    # @!attribute [rw] prompt_cache_retention
    #   @return [String, nil] the prompt cache retention policy
    # @!attribute [rw] service_tier
    #   @return [String, nil] the service tier
    STRING_FIELDS.each do |f|
      attr_reader f
      define_method(:"#{f}=") { |v| instance_variable_set(:"@#{f}", v.nil? ? nil : v.to_s) }
    end

    # @!attribute [rw] temperature
    #   @return [Float, nil] the temperature
    # @!attribute [rw] top_p
    #   @return [Float, nil] the top_p sampling parameter
    # @!attribute [rw] presence_penalty
    #   @return [Float, nil] the presence penalty
    # @!attribute [rw] frequency_penalty
    #   @return [Float, nil] the frequency penalty
    FLOAT_FIELDS.each do |f|
      attr_reader f
      define_method(:"#{f}=") { |v| instance_variable_set(:"@#{f}", v.nil? ? nil : v.to_f) }
    end

    # @!attribute [rw] max_output_tokens
    #   @return [Integer, nil] the maximum output tokens
    # @!attribute [rw] max_tool_calls
    #   @return [Integer, nil] the maximum number of tool calls
    # @!attribute [rw] top_logprobs
    #   @return [Integer, nil] the number of top log probabilities to return
    INTEGER_FIELDS.each do |f|
      attr_reader f
      define_method(:"#{f}=") { |v| instance_variable_set(:"@#{f}", v.nil? ? nil : v.to_i) }
    end

    # @!attribute [rw] parallel_tool_calls
    #   @return [Boolean, nil] whether parallel tool calls are enabled
    # @!attribute [rw] stream
    #   @return [Boolean, nil] whether to stream the response
    # @!attribute [rw] background
    #   @return [Boolean, nil] whether this is a background request
    # @!attribute [rw] store
    #   @return [Boolean, nil] whether to store the response
    BOOLEAN_FIELDS.each do |f|
      attr_reader f
      define_method(:"#{f}=") { |v| instance_variable_set(:"@#{f}", v) }
      alias_method :"#{f}?", f
    end

    # @!attribute [rw] include
    #   @return [Array, nil] fields to include in the response
    # @!attribute [rw] tool_choice
    #   @return [String, Hash, nil] the tool choice configuration
    # @!attribute [rw] metadata
    #   @return [Hash, nil] arbitrary metadata
    # @!attribute [rw] text
    #   @return [Hash, nil] text output configuration
    # @!attribute [rw] stream_options
    #   @return [Hash, nil] stream configuration options
    # @!attribute [rw] reasoning
    #   @return [Hash, nil] the reasoning configuration
    JSONIFY_FIELDS.each do |f|
      attr_reader f
      define_method(:"#{f}=") { |v| instance_variable_set(:"@#{f}", v.nil? ? nil : PromptBuilder.jsonify(v)) }
    end

    # @return [Array<Items::Base>] all conversation items
    attr_reader :items

    # @return [Integer] the index in +items+ marking the boundary after the last response
    attr_reader :response_boundary_index

    # @return [Hash, nil] provider-specific extra data for serializers.
    #   Recognized keys vary by target format. Unrecognized keys are silently
    #   ignored by each serializer.
    attr_reader :extra

    class << self
      # Deserialize a Session from a Hash produced by +to_h+ or parsed JSON.
      # Reconstructs all config fields and conversation items. Tool definitions
      # are restored without handlers; re-register handlers separately if you
      # need to invoke the tools.
      #
      # @param hash [Hash] a Hash with string keys
      # @return [Session]
      def from_h(hash)
        attrs = (STRING_FIELDS + FLOAT_FIELDS + INTEGER_FIELDS + BOOLEAN_FIELDS + JSONIFY_FIELDS)
          .each_with_object({}) { |f, acc| acc[f] = hash[f.to_s] }
        attrs[:extra] = hash["extra"] if hash["extra"]
        session = new(**attrs)

        Array(hash["input"]).each do |item_hash|
          session.add_item(Items::Base.from_h(item_hash))
        end

        Array(hash["tools"]).each do |tool_hash|
          defn = Tools::Definition.from_h(tool_hash)
          extra = defn.extra.transform_keys(&:to_sym)
          session.register_tool(defn.name, description: defn.description, parameters: defn.parameters, strict: defn.strict, **extra)
        end

        session
      end
    end

    # Create a new Session with the given options.
    # Accepts keyword arguments for all typed field groups (STRING_FIELDS,
    # FLOAT_FIELDS, INTEGER_FIELDS, BOOLEAN_FIELDS, JSONIFY_FIELDS); all default
    # to +nil+. The +system+ and +input+ shorthands auto-create a system and
    # user message if provided. Unsupported keyword options raise an ArgumentError.
    #
    # @param attributes [Hash] keyword options; see attribute declarations above
    # @option attributes [String, nil] :system optional string shorthand; a system
    #   message is automatically added with this text
    # @option attributes [String, nil] :input optional string shorthand; a user
    #   message is automatically added with this text
    # @option attributes [Hash, nil] :extra provider-specific extra data for
    #   serializers; recognized keys vary by target format
    # @raise [ArgumentError] if an unsupported option is passed
    def initialize(**attributes)
      unsupported = attributes.keys - INITIALIZE_OPTIONS
      unless unsupported.empty?
        raise ArgumentError, "unsupported option#{"s" if unsupported.size > 1}: #{unsupported.join(", ")}"
      end

      (STRING_FIELDS + FLOAT_FIELDS + INTEGER_FIELDS + BOOLEAN_FIELDS + JSONIFY_FIELDS).each do |f|
        send(:"#{f}=", attributes[f])
      end

      @extra = PromptBuilder.jsonify(attributes[:extra]) if attributes[:extra]

      @items = []
      system(attributes[:system]) if attributes[:system]

      @tool_definitions = {}
      @response_boundary_index = 0
      user(attributes[:input]) if attributes[:input]
    end

    # Add a user message to the conversation.
    #
    # @param content [String, Content::Base, Hash, Array<Content::Base>, Array<Hash>] the message content
    # @return [Items::Message] the added message
    # @example
    #  session.user("Hello, how are you?")
    #  session.user(Content::InputText.new(text: "Hello, how are you?"))
    #  session.user(type: "input_text", text: "Hello, how are you?")
    #  session.user(text: "Hello, how are you?") # type defaults to "input_text"
    #  session.user([
    #    Content::InputText.new(text: "What is in this image?"),
    #    Content::InputImage.new(url: "http://example.com/image.png")
    #  ])
    #  session.user([
    #    {type: "input_text", text: "What is in this image?"},
    #    {type: "input_image", url: "http://example.com/image.png"}
    #  ])
    def user(content)
      add_item(Items::Message.new(role: "user", content: content))
    end

    # Add an assistant message to the conversation.
    #
    # @param content [String, Content::Base, Hash, Array<Content::Base>, Array<Hash>] the message content
    # @return [Items::Message] the added message
    def assistant(content)
      add_item(Items::Message.new(role: "assistant", content: content))
    end

    # Add a system message to the conversation.
    #
    # @param content [String, Content::Base, Hash, Array<Content::Base>, Array<Hash>] the message content
    # @return [Items::Message] the added message
    # @example
    #  session.system("You are a helpful assistant.")
    #  session.system(text: "You are a helpful assistant.") # type defaults to "input_text"
    #  session.system(text: "You are a helpful assistant.", cache_point: true, cache_control: {type: "ephemeral"})
    def system(content)
      add_item(Items::Message.new(role: "system", content: content))
    end

    # Add a developer message to the conversation.
    #
    # @param content [String, Content::Base, Hash, Array<Content::Base>, Array<Hash>] the message content
    # @return [Items::Message] the added message
    def developer(content)
      add_item(Items::Message.new(role: "developer", content: content))
    end

    # Add a tool call output to the conversation.
    #
    # @param call_id [String] the tool call identifier
    # @param result [String, Array<Content::Base, Hash>, nil] the tool call result
    # @return [Items::FunctionCallOutput] the added function call output item
    def add_function_call_output(call_id:, result:)
      add_item(Items::FunctionCallOutput.new(call_id: call_id, output: result))
    end

    # Add a raw item to the conversation.
    #
    # @param item [Items::Base] the item to add
    # @return [Items::Base] the added item
    def add_item(item)
      raise ArgumentError, "item must be an instance of Items::Base" unless item.is_a?(Items::Base)

      @items << item
      item
    end

    # Add a response to the conversation. Output items are always appended
    # to +items+ so that the full history is available locally. When the
    # session is in server state mode (previous_response_id already set),
    # the id is also updated so +to_h+ can use it as a serialization
    # optimization.
    #
    # @param response [Response] the API response
    # @return [void]
    def add_response(response)
      raise ArgumentError, "response must be an instance of Response" unless response.is_a?(Response)

      @items.concat(response.output)
      # Only refresh previous_response_id when the session is already in
      # server-state mode AND the response actually carries an id; otherwise
      # leave the existing pointer alone (responses from formats that don't
      # populate `id` would otherwise silently drop us back into local state).
      self.previous_response_id = response.id if !local_state? && response.id
      @response_boundary_index = @items.length
    end

    # Clear all conversation items and the system instructions, returning the
    # session to a fresh local-state start. Model configuration and registered
    # tools are preserved.
    #
    # @return [self]
    def clear
      @items.clear
      self.instructions = nil
      self.previous_response_id = nil
      @response_boundary_index = 0
      self
    end

    # Register a tool on this session.
    #
    # @param name [String] the tool name
    # @param description [String, nil] the tool description
    # @param parameters [Hash, nil] the JSON Schema for parameters
    # @param strict [Boolean] whether strict mode is enabled
    # @param extra [Hash] provider-specific extra keyword arguments (e.g. cache_control)
    # @return [Tools::Definition] the registered definition
    def register_tool(name, description: nil, parameters: nil, strict: false, **extra)
      definition = Tools::Definition.new(
        name: name,
        description: description,
        parameters: parameters,
        strict: strict,
        **extra
      )
      @tool_definitions[name] = definition
      definition
    end

    # Register all tools from a ToolRegistry.
    #
    # @param registry [ToolRegistry] the registry to copy tools from
    # @return [void]
    def register_tools(registry)
      raise ArgumentError, "registry must be an instance of ToolRegistry" unless registry.is_a?(ToolRegistry)

      registry.definitions.each do |defn|
        extra = defn.extra.transform_keys(&:to_sym)
        register_tool(
          defn.name,
          description: defn.description,
          parameters: defn.parameters,
          strict: defn.strict,
          **extra
        )
      end
    end

    # Copy tool definitions from a ToolRegistry onto this session by name.
    # With no names, all tools in the registry are copied (same as
    # +register_tools+). Definitions are copied, so later registry changes do
    # not affect the session and the tools survive +to_h+/+from_h+ round-trips.
    #
    # @param names [Array<String, Symbol>] the tool names to copy; empty for all
    # @param registry [ToolRegistry, nil] the registry to copy from; defaults
    #   to the global +PromptBuilder.tool_registry+
    # @return [Array<Tools::Definition>] the definitions registered on the session
    # @raise [ToolNotFoundError] if a name is not registered in the registry
    # @example
    #   session.use_tools("weather", "traffic_conditions")
    #   session.use_tools                                  # all registry tools
    #   session.use_tools(:weather, registry: my_registry)
    def use_tools(*names, registry: nil)
      registry ||= PromptBuilder.tool_registry
      raise ArgumentError, "registry must be an instance of ToolRegistry" unless registry.is_a?(ToolRegistry)

      definitions = if names.empty?
        registry.definitions
      else
        names.map do |name|
          registry.definition_for(name.to_s) ||
            raise(ToolNotFoundError, "No tool registered with name: #{name.to_s.inspect}")
        end
      end

      definitions.map do |defn|
        extra = defn.extra.transform_keys(&:to_sym)
        register_tool(
          defn.name,
          description: defn.description,
          parameters: defn.parameters,
          strict: defn.strict,
          **extra
        )
      end
    end

    # Remove a single registered tool by name. Accepts a string or symbol and
    # matches regardless of how the tool's key was stored.
    #
    # @param name [String, Symbol] the tool name
    # @return [Tools::Definition, nil] the removed definition, or nil if not found
    def remove_tool(name)
      key = name.to_s
      removed = nil
      @tool_definitions.delete_if do |k, defn|
        match = k.to_s == key
        removed = defn if match
        match
      end
      removed
    end

    # Remove all registered tools from the session.
    #
    # @return [Array<Tools::Definition>] the removed tool definitions
    def clear_tools
      removed = @tool_definitions.values
      @tool_definitions.clear
      removed
    end

    # Configure JSON Schema structured output. Writes the canonical
    # +text.format+ wire hash consumed by all serializers, preserving any
    # other +text+ keys (e.g. +verbosity+) already set.
    #
    # @param schema [Hash] the JSON Schema for the response
    # @param name [String] the schema name
    # @param strict [Boolean, nil] whether strict schema adherence is requested;
    #   omitted from the format when nil
    # @param description [String, nil] an optional schema description
    # @return [Hash] the resulting +text+ configuration
    # @example
    #   session.json_output({"type" => "object", "properties" => {...}}, strict: true)
    def json_output(schema, name: "response", strict: nil, description: nil)
      format = {"type" => "json_schema", "name" => name.to_s, "schema" => schema}
      format["strict"] = strict unless strict.nil?
      format["description"] = description.to_s if description
      self.text = (text || {}).merge("format" => format)
    end

    # Configure reasoning/extended thinking portably across serializers.
    # Stores a normalized +reasoning+ configuration; each serializer maps it
    # to its native parameter:
    #
    # - +effort+ — Messages (+output_config.effort+), Chat Completions
    #   (+reasoning_effort+), Gemini (+thinkingConfig.thinkingLevel+), and
    #   Open Responses (+reasoning.effort+)
    # - +budget_tokens+ — Messages (+thinking.budget_tokens+) and Gemini
    #   (+thinkingConfig.thinkingBudget+); ignored by effort-based APIs
    # - Converse supports neither and warns once at serialization time
    #
    # Pass either +effort+ or +budget_tokens+, not both — providers reject
    # requests that set both controls. Direct +session.reasoning = {...}+
    # assignment keeps working for provider-specific keys.
    #
    # @param enabled [Boolean] pass +false+ to clear the reasoning configuration
    # @param effort [String, Symbol, nil] a portable effort level; one of
    #   +minimal+, +low+, +medium+, +high+, +xhigh+, +max+ (unsupported levels
    #   are omitted by serializers whose target API does not accept them)
    # @param budget_tokens [Integer, nil] an explicit thinking token budget
    # @return [Hash, nil] the resulting +reasoning+ configuration
    # @raise [ArgumentError] if neither or both of +effort+ and +budget_tokens+
    #   are given when enabling, or the values are invalid
    # @example
    #   session.think(effort: :medium)       # portable across serializers
    #   session.think(budget_tokens: 8_000)  # explicit where supported
    #   session.think(false)                 # disable
    def think(enabled = true, effort: nil, budget_tokens: nil)
      unless enabled
        raise ArgumentError, "cannot combine think(false) with effort or budget_tokens" if effort || budget_tokens

        return self.reasoning = nil
      end

      if effort && budget_tokens
        raise ArgumentError, "pass either effort or budget_tokens, not both"
      elsif effort.nil? && budget_tokens.nil?
        raise ArgumentError, "think requires effort: or budget_tokens:"
      end

      if effort
        effort = effort.to_s
        unless THINK_EFFORT_LEVELS.include?(effort)
          raise ArgumentError, "effort must be one of: #{THINK_EFFORT_LEVELS.join(", ")}"
        end
        self.reasoning = {"effort" => effort}
      else
        budget_tokens = Integer(budget_tokens)
        raise ArgumentError, "budget_tokens must be positive" unless budget_tokens.positive?

        self.reasoning = {"budget_tokens" => budget_tokens}
      end
    end

    # Return all tool definitions registered on this session.
    #
    # @return [Array<Tools::Definition>] all tool definitions
    def tool_definitions
      @tool_definitions.values
    end

    # Create a new Session with the same configuration and tools but no items.
    #
    # @return [Session] a new session with cloned configuration
    def clone_config
      session = Session.new(**config_hash)
      @tool_definitions.each do |name, defn|
        extra = defn.extra.transform_keys(&:to_sym)
        session.register_tool(
          name,
          description: defn.description,
          parameters: defn.parameters,
          strict: defn.strict,
          **extra
        )
      end
      session
    end

    # Check if this session is in local state mode (no previous_response_id). This
    # indicates that the full conversation history is stored in the session and will be
    # sent with each request. Once a response with an id is added, the session switches
    # to server state mode, where only new items after the last response are sent
    # and the previous_response_id is used to reference the last response.
    #
    # @return [Boolean]
    def local_state?
      @previous_response_id.nil?
    end

    # Serialize to an Open Responses API request Hash with string keys.
    #
    # @return [Hash]
    def to_h
      h = {}
      h["model"] = @model if @model
      h["instructions"] = @instructions if @instructions

      h["input"] = @items.map(&:to_h) unless @items.empty?
      h["previous_response_id"] = @previous_response_id if @previous_response_id

      h["tools"] = tool_definitions.map(&:to_h) unless @tool_definitions.empty?

      (STRING_FIELDS - %i[model instructions previous_response_id]).each do |f|
        val = send(f)
        h[f.to_s] = val if val
      end
      FLOAT_FIELDS.each { |f|
        val = send(f)
        h[f.to_s] = val if val
      }
      INTEGER_FIELDS.each { |f|
        val = send(f)
        h[f.to_s] = val if val
      }
      BOOLEAN_FIELDS.each { |f|
        val = send(f)
        h[f.to_s] = val unless val.nil?
      }
      JSONIFY_FIELDS.each { |f|
        val = send(f)
        h[f.to_s] = val if val
      }
      h["extra"] = @extra if @extra

      h
    end

    # Export this session to an alternate API format using the given serializer.
    #
    # @param serializer_class [Class, Symbol] a serializer class (e.g. Serializers::ChatCompletion)
    #   or a symbol shorthand (+:open_responses+, +:chat_completion+, +:messages+,
    #   +:gemini+, +:converse+)
    # @return [Hash] the serialized request payload
    # @raise [ArgumentError] if a symbol is given that does not map to a known serializer
    def request_payload(serializer_class)
      Serializers.resolve(serializer_class).request_payload(self)
    end

    private

    def config_hash
      h = (STRING_FIELDS + FLOAT_FIELDS + INTEGER_FIELDS + BOOLEAN_FIELDS + JSONIFY_FIELDS - %i[previous_response_id])
        .each_with_object({}) { |f, acc| acc[f] = send(f) }
      h[:extra] = @extra if @extra
      h
    end
  end
end
