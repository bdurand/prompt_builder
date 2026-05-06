# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents video input content in a message.
    class InputVideo < Base
      # @return [String, nil] the video URL
      attr_reader :video_url

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      # Create a new InputVideo content object.
      #
      # @param video_url [String, nil] the video URL
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(video_url: nil, **extra)
        @video_url = video_url&.to_s
        @extra = extra.transform_keys(&:to_s)
      end

      class << self
        # Deserialize an InputVideo from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [InputVideo]
        def from_h(hash)
          new(video_url: hash["video_url"], **hash.except("type", "video_url").transform_keys(&:to_sym))
        end
      end

      # Serialize to a Hash with string keys. Nil values are omitted.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "input_video"}
        h["video_url"] = @video_url if @video_url
        h = PromptBuilder.jsonify(@extra).merge(h) unless @extra.empty?
        h
      end
    end
  end
end
