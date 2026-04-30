# frozen_string_literal: true

module PromptBuilder
  module Items
    # Represents a message item in a conversation. Messages have a role
    # and an array of content objects.
    class Message < Base
      # @return [String, nil] the message identifier
      attr_reader :id

      # @return [String] the message role (e.g. "user", "assistant", "system", "developer")
      attr_reader :role

      # @return [String, nil] the message status
      attr_reader :status

      # @return [String, nil] the message phase
      attr_reader :phase

      # @return [Array<Content::Base>] the content objects
      attr_reader :content

      # Create a new Message item.
      #
      # @param id [String, nil] the message identifier
      # @param role [String] the message role
      # @param status [String, nil] the message status
      # @param phase [String, nil] the message phase
      # @param content [Array<Content::Base>] the content objects
      def initialize(role:, content:, id: nil, status: nil, phase: nil)
        @id = id&.to_s
        @role = role&.to_s
        @status = status&.to_s
        @phase = phase&.to_s
        @content = normalize_content(content)
      end

      class << self
        # Deserialize a Message from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [Message]
        def from_h(hash)
          content = (hash["content"] || []).map { |c| Content::Base.from_h(c) }
          new(
            id: hash["id"],
            role: hash["role"],
            status: hash["status"],
            phase: hash["phase"],
            content: content
          )
        end
      end

      # Serialize to a Hash with string keys.
      #
      # @return [Hash]
      def to_h
        hash = {
          "type" => "message",
          "role" => @role,
          "content" => @content.map(&:to_h)
        }
        hash["id"] = @id if @id
        hash["status"] = @status if @status
        hash["phase"] = @phase if @phase
        hash
      end

      private

      def normalize_content(content)
        case content
        when String
          [Content::InputText.new(text: content)]
        when Array
          content.map do |c|
            case c
            when Hash
              Content::Base.from_h(c)
            when Content::Base
              c
            else
              raise InvalidItemError, "Unsupported content element: #{c.class}"
            end
          end
        else
          raise InvalidItemError, "Unsupported content type: #{content.class}"
        end
      end
    end
  end
end
