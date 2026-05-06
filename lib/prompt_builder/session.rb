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
    # to +nil+. The +input+ shorthand auto-creates a user message if provided.
    #
    # @param attributes [Hash] keyword options; see attribute declarations above
    # @option attributes [String, nil] :input optional string shorthand; a user
    #   message is automatically added with this text
    # @option attributes [Hash, nil] :extra provider-specific extra data for
    #   serializers; recognized keys vary by target format
    def initialize(**attributes)
      (STRING_FIELDS + FLOAT_FIELDS + INTEGER_FIELDS + BOOLEAN_FIELDS + JSONIFY_FIELDS).each do |f|
        send(:"#{f}=", attributes[f])
      end
      @extra = PromptBuilder.jsonify(attributes[:extra]) if attributes[:extra]
      @items = []
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
    #  session.user([
    #    Content::InputText.new(text: "What is in this image?"),
    #    Content::InputImage.new(image_url: "http://example.com/image.png")
    #  ])
    #  session.user([
    #    {type: "input_text", text: "What is in this image?"},
    #    {type: "input_image", image_url: "http://example.com/image.png"}
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

    # Add a raw item to the conversation.
    #
    # @param item [Items::Base] the item to add
    # @return [Items::Base] the added item
    def add_item(item)
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
      @items.concat(response.output)
      # Only refresh previous_response_id when the session is already in
      # server-state mode AND the response actually carries an id; otherwise
      # leave the existing pointer alone (responses from formats that don't
      # populate `id` would otherwise silently drop us back into local state).
      self.previous_response_id = response.id if !local_state? && response.id
      @response_boundary_index = @items.length
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

    # Check if this session is in local state mode (no previous_response_id).
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

      if local_state?
        h["input"] = @items.map(&:to_h) unless @items.empty?
      else
        h["previous_response_id"] = @previous_response_id
        new_items = @items[@response_boundary_index..]
        h["input"] = new_items.map(&:to_h) if new_items && !new_items.empty?
      end

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
