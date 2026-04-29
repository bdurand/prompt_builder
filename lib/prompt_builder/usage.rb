# frozen_string_literal: true

module PromptBuilder
  # Value object representing token usage statistics from an API response.
  class Usage
    # @return [Integer, nil] number of input tokens
    attr_reader :input_tokens

    # @return [Integer, nil] number of output tokens
    attr_reader :output_tokens

    # @return [Integer, nil] total number of tokens
    attr_reader :total_tokens

    # @return [Hash, nil] input token details
    attr_reader :input_tokens_details

    # @return [Hash, nil] output token details
    attr_reader :output_tokens_details

    # Create a new Usage value object.
    #
    # @param input_tokens [Integer, nil] number of input tokens
    # @param output_tokens [Integer, nil] number of output tokens
    # @param total_tokens [Integer, nil] total number of tokens
    # @param input_tokens_details [Hash, nil] input token details
    # @param output_tokens_details [Hash, nil] output token details
    # @param reasoning_tokens [Integer, nil] number of reasoning tokens
    def initialize(input_tokens: nil, output_tokens: nil, total_tokens: nil,
      input_tokens_details: nil, output_tokens_details: nil, reasoning_tokens: nil)
      @input_tokens = input_tokens
      @output_tokens = output_tokens
      @total_tokens = total_tokens
      @input_tokens_details = input_tokens_details
      @output_tokens_details = output_tokens_details || build_output_tokens_details(reasoning_tokens)
    end

    class << self
      # Deserialize a Usage from a Hash.
      #
      # @param hash [Hash] a Hash with string keys
      # @return [Usage]
      def from_h(hash)
        input_tokens_details = hash["input_tokens_details"]
        output_tokens_details = hash["output_tokens_details"]

        new(
          input_tokens: hash["input_tokens"],
          output_tokens: hash["output_tokens"],
          total_tokens: hash["total_tokens"],
          input_tokens_details: input_tokens_details,
          output_tokens_details: output_tokens_details,
          reasoning_tokens: hash["reasoning_tokens"] || output_tokens_details&.fetch("reasoning_tokens", nil)
        )
      end
    end

    # Number of cached input tokens.
    #
    # @return [Integer, nil]
    def cached_tokens
      @input_tokens_details&.fetch("cached_tokens", nil)
    end

    # Number of tokens used for cache creation. This is specific only to the Anthropic Messages API format.
    #
    # @return [Integer, nil]
    def cache_creation_input_tokens
      @input_tokens_details&.fetch("cache_creation_input_tokens", nil)
    end

    # Number of reasoning tokens.
    #
    # @return [Integer, nil]
    def reasoning_tokens
      @output_tokens_details&.fetch("reasoning_tokens", nil)
    end

    # Serialize to a Hash with string keys. Nil values are omitted.
    #
    # @return [Hash]
    def to_h
      h = {}
      h["input_tokens"] = @input_tokens if @input_tokens
      h["output_tokens"] = @output_tokens if @output_tokens
      h["total_tokens"] = @total_tokens if @total_tokens
      h["input_tokens_details"] = @input_tokens_details if @input_tokens_details
      h["output_tokens_details"] = @output_tokens_details if @output_tokens_details
      h
    end

    private

    def build_output_tokens_details(reasoning_tokens)
      return nil unless reasoning_tokens

      {"reasoning_tokens" => reasoning_tokens}
    end
  end
end
