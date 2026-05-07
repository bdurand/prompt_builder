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

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      # Create a new InputFile content object.
      #
      # @param file_url [String, nil] the file URL
      # @param file_data [String, nil] base64-encoded file data
      # @param filename [String, nil] the filename
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(file_url: nil, file_data: nil, filename: nil, **extra)
        @file_url = file_url&.to_s
        @file_data = file_data&.to_s
        @filename = filename&.to_s
        @extra = extra.transform_keys(&:to_s)
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
            **hash.except("type", "file_url", "file_data", "filename").transform_keys(&:to_sym)
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
        h = PromptBuilder.jsonify(@extra).merge(h) unless @extra.empty?
        h
      end
    end
  end
end
