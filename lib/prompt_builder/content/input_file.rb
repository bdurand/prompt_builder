# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents file input content in a message.
    class InputFile < Base
      # @return [String, nil] the file URL (may be a data URL)
      attr_reader :url

      # @return [String, nil] the filename
      attr_reader :filename

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      class << self
        # Deserialize an InputFile from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [InputFile]
        def from_h(hash)
          new(
            url: hash["url"],
            filename: hash["filename"],
            **hash.except("type", "url", "filename").transform_keys(&:to_sym)
          )
        end
      end

      # Create a new InputFile content object.
      #
      # @param url [String, nil] the file URL or data URL
      # @param filename [String, nil] the filename
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(url: nil, filename: nil, **extra)
        @filename = filename&.to_s
        @extra = normalize_extra_kwargs(extra)
        @url = url&.to_s
      end

      # Serialize to a Hash with string keys. Nil values are omitted.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "input_file"}
        h["url"] = @url if @url
        h["filename"] = @filename if @filename
        h = PromptBuilder.jsonify(@extra).merge(h) unless @extra.empty?
        h
      end

      private

      def normalize_extra_kwargs(extra)
        nested = extra.delete(:extra)
        nested = extra.delete("extra") if nested.nil?
        nested_hash = nested.is_a?(Hash) ? nested : {}

        PromptBuilder.jsonify(nested_hash.merge(extra)).transform_keys(&:to_s)
      end
    end
  end
end
