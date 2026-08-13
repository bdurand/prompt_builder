# frozen_string_literal: true

module PromptBuilder
  module Serializers
    # Serializer for the Amazon Bedrock Converse API format.
    # Delegates request and response handling to dedicated nested classes.
    class Converse < Base
      autoload :Request, File.expand_path("converse/request", __dir__)
      autoload :Response, File.expand_path("converse/response", __dir__)

      class << self
        # Export a session to Converse request payload.
        #
        # @param session [Session] the session to export
        # @return [Hash] the serialized request payload
        def request_payload(session)
          Request.request_payload(session)
        end

        # Parse a Converse response into a PromptBuilder::Response.
        #
        # @param hash [Hash] the response hash in Converse format
        # @param headers [Hash, #each, nil] the HTTP response headers; the
        #   Converse API returns the response id in the request metadata
        #   headers rather than in the body
        # @return [PromptBuilder::Response] the parsed response
        def parse_response(hash, headers: nil)
          Response.parse_response(hash, headers: headers)
        end
      end
    end
  end
end
