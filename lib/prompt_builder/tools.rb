# frozen_string_literal: true

module PromptBuilder
  module Tools
    autoload :Choice, File.expand_path("tools/choice", __dir__)
    autoload :Definition, File.expand_path("tools/definition", __dir__)
  end
end
