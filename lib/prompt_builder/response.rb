# frozen_string_literal: true

module PromptBuilder
  # Represents a parsed API response from the Open Responses API.
  # All fields are optional and will be nil if not present in the response.
  class Response
    # All scalar fields returned by the API. Used to drive attr_reader,
    # initialize, from_h, and to_h so each name is declared once.
    FIELDS = %i[
      id
      object
      created_at
      completed_at
      status
      incomplete_details
      model
      previous_response_id
      instructions
      error
      tools
      tool_choice
      truncation
      parallel_tool_calls
      top_p
      presence_penalty
      frequency_penalty
      top_logprobs
      temperature
      reasoning
      max_output_tokens
      max_tool_calls
      store
      background
      service_tier
      metadata
      safety_identifier prompt_cache_key
    ].freeze

    # Boolean fields that may legitimately be false; serialized with a nil? check.
    BOOLEAN_FIELDS = %i[parallel_tool_calls store background].freeze

    # @!attribute [r] id
    #   @return [String, nil] the response identifier
    # @!attribute [r] object
    #   @return [String, nil] the object type
    # @!attribute [r] created_at
    #   @return [Integer, nil] creation timestamp
    # @!attribute [r] completed_at
    #   @return [Integer, nil] completion timestamp
    # @!attribute [r] status
    #   @return [String, nil] the response status
    # @!attribute [r] incomplete_details
    #   @return [Hash, nil] details about why the response is incomplete
    # @!attribute [r] model
    #   @return [String, nil] the model identifier
    # @!attribute [r] previous_response_id
    #   @return [String, nil] the previous response identifier
    # @!attribute [r] instructions
    #   @return [String, nil] the system instructions
    # @!attribute [r] error
    #   @return [Hash, nil] error information
    # @!attribute [r] tools
    #   @return [Array<Hash>, nil] the tool definitions
    # @!attribute [r] tool_choice
    #   @return [String, Hash, nil] the tool choice configuration
    # @!attribute [r] truncation
    #   @return [String, nil] the truncation strategy
    # @!attribute [r] parallel_tool_calls
    #   @return [Boolean, nil] whether parallel tool calls are enabled
    # @!attribute [r] top_p
    #   @return [Float, nil] the top_p sampling parameter
    # @!attribute [r] presence_penalty
    #   @return [Float, nil] the presence penalty
    # @!attribute [r] frequency_penalty
    #   @return [Float, nil] the frequency penalty
    # @!attribute [r] top_logprobs
    #   @return [Integer, nil] the number of top log probabilities to return
    # @!attribute [r] temperature
    #   @return [Float, nil] the temperature
    # @!attribute [r] reasoning
    #   @return [Hash, nil] the reasoning configuration
    # @!attribute [r] max_output_tokens
    #   @return [Integer, nil] the maximum output tokens
    # @!attribute [r] max_tool_calls
    #   @return [Integer, nil] the maximum number of tool calls
    # @!attribute [r] store
    #   @return [Boolean, nil] whether to store the response
    # @!attribute [r] background
    #   @return [Boolean, nil] whether this is a background response
    # @!attribute [r] service_tier
    #   @return [String, nil] the service tier
    # @!attribute [r] metadata
    #   @return [Hash, nil] arbitrary metadata
    # @!attribute [r] safety_identifier
    #   @return [String, nil] the safety identifier
    # @!attribute [r] prompt_cache_key
    #   @return [String, nil] the prompt cache key
    # @!attribute [r] text_config
    #   @return [Hash, nil] the text configuration
    # @!attribute [r] output
    #   @return [Array<Items::Base>] the output items
    # @!attribute [r] usage
    #   @return [Usage, nil] token usage statistics
    attr_reader(*FIELDS, :text_config, :output, :usage)

    BOOLEAN_FIELDS.each { |f| alias_method("#{f}?", f) }

    # Create a new Response.
    #
    # @param attributes [Hash] response attributes
    def initialize(**attributes)
      FIELDS.each { |f| instance_variable_set(:"@#{f}", attributes[f]) }
      @text_config = attributes[:text_config]
      @output = attributes[:output] || []
      @usage = attributes[:usage]
    end

    class << self
      # Deserialize a Response from a Hash.
      #
      # @param hash [Hash] a Hash with string keys from the API response
      # @return [Response]
      def from_h(hash)
        output = (hash["output"] || []).map { |item| Items::Base.from_h(item) }
        usage = hash["usage"] ? Usage.from_h(hash["usage"]) : nil

        attrs = FIELDS.each_with_object({}) { |f, acc| acc[f] = hash[f.to_s] }
        new(**attrs, text_config: hash["text"], output: output, usage: usage)
      end
    end

    # Check if the response completed successfully.
    #
    # @return [Boolean]
    def completed?
      @status == "completed"
    end

    # Check if the response failed.
    #
    # @return [Boolean]
    def failed?
      @status == "failed"
    end

    # Check if the response is incomplete.
    #
    # @return [Boolean]
    def incomplete?
      @status == "incomplete"
    end

    # Check if the response contains any tool calls.
    #
    # @return [Boolean]
    def has_tool_calls?
      @output.any? { |item| item.is_a?(Items::FunctionCall) }
    end

    # Get all function call items from the output.
    #
    # @return [Array<Items::FunctionCall>]
    def tool_calls
      @output.select { |item| item.is_a?(Items::FunctionCall) }
    end

    # Extract the text from the first output message. Returns the concatenated
    # text of all OutputText content blocks in the first message.
    #
    # @return [String, nil] the text content, or nil if no message with text is found
    def text
      @output.each do |item|
        next unless item.is_a?(Items::Message)

        texts = item.content.select { |c| c.is_a?(Content::OutputText) }
        return texts.map(&:text).join unless texts.empty?
      end
      nil
    end

    # Serialize to a Hash with string keys. Nil values are omitted.
    #
    # @return [Hash]
    def to_h
      h = {}
      FIELDS.each do |f|
        val = instance_variable_get(:"@#{f}")
        if BOOLEAN_FIELDS.include?(f)
          h[f.to_s] = val unless val.nil?
        elsif val
          h[f.to_s] = val
        end
      end
      h["text"] = @text_config if @text_config
      h["output"] = @output.map(&:to_h) unless @output.empty?
      h["usage"] = @usage.to_h if @usage
      h
    end
  end
end
