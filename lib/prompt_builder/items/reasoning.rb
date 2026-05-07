# frozen_string_literal: true

module PromptBuilder
  module Items
    # Represents a reasoning item in a conversation. This captures the
    # model's chain-of-thought reasoning output.
    class Reasoning < Base
      # @return [String, nil] the reasoning identifier
      attr_reader :id

      # @return [String, nil] the reasoning status
      attr_reader :status

      # @return [String, nil] the encrypted reasoning content
      attr_reader :encrypted_content

      # @return [Array<Hash>] summary blocks
      attr_reader :summary

      # @return [Array<Hash>] reasoning content blocks
      attr_reader :content

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      # Create a new Reasoning item.
      #
      # @param id [String, nil] the reasoning identifier
      # @param status [String, nil] the reasoning status
      # @param encrypted_content [String, nil] the encrypted reasoning content
      # @param summary [Array<Hash>] summary blocks
      # @param content [Array<Hash>] reasoning content blocks
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(id: nil, status: nil, encrypted_content: nil, summary: [], content: [], **extra)
        @id = id&.to_s
        @status = status&.to_s
        @encrypted_content = encrypted_content&.to_s
        @summary = PromptBuilder.jsonify(summary)
        @content = PromptBuilder.jsonify(content)
        @extra = extra.transform_keys(&:to_s)
      end

      class << self
        # Deserialize a Reasoning item from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [Reasoning]
        def from_h(hash)
          new(
            id: hash["id"],
            status: hash["status"],
            encrypted_content: hash["encrypted_content"],
            summary: hash["summary"] || [],
            content: hash["content"] || [],
            **hash.except("type", "id", "status", "encrypted_content", "summary", "content").transform_keys(&:to_sym)
          )
        end
      end

      # Serialize to a Hash with string keys. Nil and empty values are omitted.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "reasoning"}
        h["id"] = @id if @id
        h["status"] = @status if @status
        h["encrypted_content"] = @encrypted_content if @encrypted_content
        h["summary"] = @summary unless @summary.empty?
        h["content"] = @content unless @content.empty?
        h = PromptBuilder.jsonify(@extra).merge(h) unless @extra.empty?
        h
      end
    end
  end
end
