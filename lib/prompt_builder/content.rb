# frozen_string_literal: true

module PromptBuilder
  module Content
    autoload :Base, File.expand_path("content/base", __dir__)
    autoload :InputFile, File.expand_path("content/input_file", __dir__)
    autoload :InputImage, File.expand_path("content/input_image", __dir__)
    autoload :InputText, File.expand_path("content/input_text", __dir__)
    autoload :InputVideo, File.expand_path("content/input_video", __dir__)
    autoload :OutputText, File.expand_path("content/output_text", __dir__)
    autoload :ReasoningText, File.expand_path("content/reasoning_text", __dir__)
    autoload :RefusalContent, File.expand_path("content/refusal_content", __dir__)
    autoload :SummaryText, File.expand_path("content/summary_text", __dir__)
    autoload :Text, File.expand_path("content/text", __dir__)

    class << self
      # Construct a base64-encoded data URL from raw binary data and a content type.
      # Delegates to {PromptBuilder.data_url}.
      #
      # @param data [String] the raw binary data
      # @param content_type [String] the MIME content type (e.g. "image/png", "application/pdf")
      # @return [String] a data URL in the form "data:<content_type>;base64,<encoded_data>"
      def data_url(data, content_type)
        PromptBuilder.data_url(data, content_type)
      end
    end
  end
end
