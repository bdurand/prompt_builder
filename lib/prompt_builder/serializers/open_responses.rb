# frozen_string_literal: true

module PromptBuilder
  module Serializers
    # Serializer for OpenAI Open Responses API format.
    # Delegates request and response handling to dedicated nested classes.
    class OpenResponses < Base
      autoload :Request, File.expand_path("open_responses/request", __dir__)
      autoload :Response, File.expand_path("open_responses/response", __dir__)

      class << self
        # Export a session to Open Responses API request payload.
        #
        # @param session [Session] the session to export
        # @return [Hash] the serialized request payload
        def request_payload(session)
          Request.request_payload(session)
        end

        # Parse an Open Responses response into an PromptBuilder::Response.
        #
        # @param hash [Hash] the response hash in Open Responses format
        # @return [PromptBuilder::Response] the parsed response
        def parse_response(hash)
          Response.parse_response(hash)
        end
      end
    end
  end
end
