# frozen_string_literal: true

module PromptBuilder
  module Serializers
    # Serializer for the OpenAI Chat Completions API format.
    # Delegates request and response handling to dedicated nested classes.
    class ChatCompletion < Base
      autoload :Request, File.expand_path("chat_completion/request", __dir__)
      autoload :Response, File.expand_path("chat_completion/response", __dir__)

      class << self
        # Export a session to Chat Completions request payload.
        #
        # @param session [Session] the session to export
        # @return [Hash] the serialized request payload
        def request_payload(session)
          Request.request_payload(session)
        end
      end
    end
  end
end
