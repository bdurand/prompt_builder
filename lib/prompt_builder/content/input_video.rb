# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents video input content in a message.
    class InputVideo < Base
      # @return [String, nil] the video URL
      attr_reader :video_url

      # Create a new InputVideo content object.
      #
      # @param video_url [String, nil] the video URL
      def initialize(video_url: nil)
        @video_url = video_url
      end

      class << self
        # Deserialize an InputVideo from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [InputVideo]
        def from_h(hash)
          new(video_url: hash["video_url"])
        end
      end

      # Serialize to a Hash with string keys. Nil values are omitted.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "input_video"}
        h["video_url"] = @video_url if @video_url
        h
      end
    end

    Base.register_type("input_video", InputVideo)
  end
end
