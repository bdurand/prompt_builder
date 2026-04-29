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

      # Create a new InputFile content object.
      #
      # @param file_url [String, nil] the file URL
      # @param file_data [String, nil] base64-encoded file data
      # @param filename [String, nil] the filename
      def initialize(file_url: nil, file_data: nil, filename: nil)
        @file_url = file_url
        @file_data = file_data
        @filename = filename
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
            filename: hash["filename"]
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
        h
      end
    end

    Base.register_type("input_file", InputFile)
  end
end
