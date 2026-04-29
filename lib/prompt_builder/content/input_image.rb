# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents image input content in a message.
    class InputImage < Base
      # @return [String, nil] the image URL
      attr_reader :image_url

      # @return [String, nil] base64-encoded image data
      attr_reader :data

      # @return [String, nil] the media type of the image
      attr_reader :media_type

      # @return [String, nil] the detail level for the image
      attr_reader :detail

      # Create a new InputImage content object.
      #
      # @param image_url [String, nil] the image URL
      # @param data [String, nil] base64-encoded image data
      # @param media_type [String, nil] the media type of the image
      # @param detail [String, nil] the image detail level
      def initialize(image_url: nil, data: nil, media_type: nil, detail: nil)
        @image_url = image_url
        @data = data
        @media_type = media_type
        @detail = detail
      end

      class << self
        # Deserialize an InputImage from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [InputImage]
        def from_h(hash)
          new(
            image_url: hash["image_url"],
            data: hash["data"],
            media_type: hash["media_type"],
            detail: hash["detail"]
          )
        end
      end

      # Serialize to a Hash with string keys. Nil values are omitted.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "input_image"}
        h["image_url"] = @image_url if @image_url
        h["data"] = @data if @data
        h["media_type"] = @media_type if @media_type
        h["detail"] = @detail if @detail
        h
      end
    end

    Base.register_type("input_image", InputImage)
  end
end
