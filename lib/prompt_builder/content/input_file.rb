# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents file input content in a message.
    class InputFile < Base
      # @return [String, nil] the file URL
      attr_reader :file_url

      # @return [String, nil] base64-encoded file data
      attr_reader :file_data

      # @return [String, nil] the filename
      attr_reader :filename

      # @return [String, nil] the file identifier (for files uploaded to the
      #   provider). On OpenAI this is a Files API id; on Gemini this is a
      #   Files API resource name.
      attr_reader :file_id

      # @return [String, nil] the media type of the file (e.g. "application/pdf",
      #   "text/plain"). Required by some providers when the type cannot be
      #   inferred from the filename or URL extension.
      attr_reader :media_type

      # Create a new InputFile content object.
      #
      # @param file_url [String, nil] the file URL
      # @param file_data [String, nil] base64-encoded file data
      # @param filename [String, nil] the filename
      # @param file_id [String, nil] the provider file identifier
      # @param media_type [String, nil] the media type of the file
      def initialize(file_url: nil, file_data: nil, filename: nil, file_id: nil, media_type: nil)
        @file_url = file_url&.to_s
        @file_data = file_data&.to_s
        @filename = filename&.to_s
        @file_id = file_id&.to_s
        @media_type = media_type&.to_s
      end

      class << self
        # Deserialize an InputFile from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [InputFile]
        def from_h(hash)
          new(
            file_url: hash["file_url"],
            file_data: hash["file_data"],
            filename: hash["filename"],
            file_id: hash["file_id"],
            media_type: hash["media_type"]
          )
        end
      end

      # Serialize to a Hash with string keys. Nil values are omitted.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "input_file"}
        h["file_url"] = @file_url if @file_url
        h["file_data"] = @file_data if @file_data
        h["filename"] = @filename if @filename
        h["file_id"] = @file_id if @file_id
        h["media_type"] = @media_type if @media_type
        h
      end
    end
  end
end
