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

        # Parse a Chat Completions response into an PromptBuilder::Response.
        #
        # @param hash [Hash] the response hash in Chat Completions format
        # @param headers [Hash, #each, nil] the HTTP response headers
        # @return [PromptBuilder::Response] the parsed response
        def parse_response(hash, headers: nil)
          Response.parse_response(hash, headers: headers)
        end
      end
    end
  end
end
