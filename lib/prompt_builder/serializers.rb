# frozen_string_literal: true

module PromptBuilder
  module Serializers
    autoload :Base, File.expand_path("serializers/base", __dir__)
    autoload :ChatCompletion, File.expand_path("serializers/chat_completion", __dir__)
    autoload :Messages, File.expand_path("serializers/messages", __dir__)
    autoload :OpenResponses, File.expand_path("serializers/open_responses", __dir__)
  end
end
