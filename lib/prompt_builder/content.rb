# frozen_string_literal: true

module PromptBuilder
  module Content
    autoload :Base, File.expand_path("content/base", __dir__)
    autoload :InputFile, File.expand_path("content/input_file", __dir__)
    autoload :InputImage, File.expand_path("content/input_image", __dir__)
    autoload :InputText, File.expand_path("content/input_text", __dir__)
    autoload :InputVideo, File.expand_path("content/input_video", __dir__)
    autoload :OutputText, File.expand_path("content/output_text", __dir__)
    autoload :RefusalContent, File.expand_path("content/refusal_content", __dir__)
  end
end
