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
      # @param detail [String, nil] the image detail level
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(url: nil, detail: nil, **extra)
        @detail = detail&.to_s
        @extra = normalize_extra_kwargs(extra)
        @url = url&.to_s
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
