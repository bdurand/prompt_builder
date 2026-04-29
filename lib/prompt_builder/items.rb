# frozen_string_literal: true

module PromptBuilder
  module Items
    autoload :Base, File.expand_path("items/base", __dir__)
    autoload :Compaction, File.expand_path("items/compaction", __dir__)
    autoload :FunctionCall, File.expand_path("items/function_call", __dir__)
    autoload :FunctionCallOutput, File.expand_path("items/function_call_output", __dir__)
    autoload :ItemReference, File.expand_path("items/item_reference", __dir__)
    autoload :Message, File.expand_path("items/message", __dir__)
    autoload :Reasoning, File.expand_path("items/reasoning", __dir__)
  end
end
