# frozen_string_literal: true

module PromptBuilder
  module Content
    # Represents image input content in a message.
    class InputImage < Base
      # @return [String, nil] the image URL (may be a fully qualified URL or a
      #   base64-encoded data URL such as +"data:image/png;base64,..."+ )
      attr_reader :url

      # @return [String, nil] the detail level for the image
      attr_reader :detail

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      class << self
        # Deserialize an InputImage from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [InputImage]
        def from_h(hash)
          new(
            url: hash["url"],
            detail: hash["detail"],
            **hash.except("type", "url", "detail").transform_keys(&:to_sym)
          )
        end
      end

      # Create a new InputImage content object.
      #
      # @param url [String, nil] the image URL or data URL
      # @param data [String, nil] raw binary image data (will be converted to a base64 data URL)
      # @param detail [String, nil] the image detail level
      # @param extra [Hash] provider-specific extra keyword arguments
      #
      # @raise [ArgumentError] if both url and data are provided
      def initialize(url: nil, data: nil, detail: nil, **extra)
        raise ArgumentError, "cannot provide both url and data" if url && data

        @detail = detail&.to_s
        @extra = normalize_extra_kwargs(extra)
        @url = url&.to_s
        self.data = data if data
      end

      # Return the decoded binary data if the URL is a base64 data URL.
      #
      # @return [String, nil] the decoded binary data or nil
      def data
        parsed = PromptBuilder.parse_data_url(@url)
        return nil unless parsed

        parsed[1].unpack1("m0")
      end

      # Set raw binary data, converting it to a base64 data URL.
      #
      # @param value [String] the raw binary data
      def data=(value)
        return unless value

        media_type = @extra && @extra["media_type"] || "application/octet-stream"
        @url = "data:#{media_type};base64,#{[value].pack("m0")}"
      end

      # Serialize to a Hash with string keys. Nil values are omitted.
      #
      # @return [Hash]
      def to_h
        h = {"type" => "input_image"}
        h["url"] = @url if @url
        h["detail"] = @detail if @detail
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
