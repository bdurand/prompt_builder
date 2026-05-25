# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents video input content in a message.
    class InputVideo < Base
      # @return [String, nil] the video URL
      attr_reader :url

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      class << self
        # Deserialize an InputVideo from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [InputVideo]
        def from_h(hash)
          new(url: hash["url"], **hash.except("type", "url").transform_keys(&:to_sym))
        end
      end

      # Create a new InputVideo content object.
      #
      # @param url [String, nil] the video URL
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(url: nil, **extra)
        @url = url&.to_s
        @extra = extra.transform_keys(&:to_s)
      end

      # Serialize to a Hash with string keys. Nil values are omitted.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "input_video"}
        h["url"] = @url if @url
        h = PromptBuilder.jsonify(@extra).merge(h) unless @extra.empty?
        h
      end
    end
  end
end
