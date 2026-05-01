# frozen_string_literal: true

module PromptBuilder
  module Serializers
    autoload :Base, File.expand_path("serializers/base", __dir__)
    autoload :ChatCompletion, File.expand_path("serializers/chat_completion", __dir__)
    autoload :Gemini, File.expand_path("serializers/gemini", __dir__)
    autoload :Messages, File.expand_path("serializers/messages", __dir__)
    autoload :OpenResponses, File.expand_path("serializers/open_responses", __dir__)

    # Mapping of shorthand symbols to serializer classes.
    ALIASES = {
      chat_completion: ChatCompletion,
      gemini: Gemini,
      messages: Messages,
      open_responses: OpenResponses
    }.freeze

    # Resolve a serializer class from a symbol or class reference.
    #
    # @param serializer [Class, Symbol] a serializer class or a symbol shorthand
    #   (+:open_responses+, +:chat_completion+, +:messages+)
    # @return [Class] the resolved serializer class
    # @raise [ArgumentError] if a symbol is given that does not map to a known serializer
    def self.resolve(serializer)
      return serializer unless serializer.is_a?(Symbol)

      ALIASES.fetch(serializer) do
        raise ArgumentError, "Unknown serializer: #{serializer.inspect}. Valid options: #{ALIASES.keys.map(&:inspect).join(", ")}"
      end
    end
  end
end
