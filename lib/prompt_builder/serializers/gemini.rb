# frozen_string_literal: true

module PromptBuilder
  module Serializers
    # Serializer for the Google Gemini API format.
    # Delegates request and response handling to dedicated nested classes.
    class Gemini < Base
      autoload :Request, File.expand_path("gemini/request", __dir__)
      autoload :Response, File.expand_path("gemini/response", __dir__)

      class << self
        # Export a session to Gemini request payload.
        #
        # @param session [Session] the session to export
        # @return [Hash] the serialized request payload
        def request_payload(session)
          Request.request_payload(session)
        end

        # Parse a Gemini response into a PromptBuilder::Response.
        #
        # @param hash [Hash] the response hash in Gemini format
        # @param headers [Hash, #each, nil] the HTTP response headers
        # @return [PromptBuilder::Response] the parsed response
        def parse_response(hash, headers: nil)
          Response.parse_response(hash, headers: headers)
        end
      end
    end
  end
end
