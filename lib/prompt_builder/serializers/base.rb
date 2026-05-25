# frozen_string_literal: true

module PromptBuilder
  module Serializers
    # Base class for format serializers. Provides a common interface for
    # exporting sessions and parsing responses in alternate API formats.
    class Base
      class << self
        # Export a session to the target format's request payload.
        #
        # @param session [Session] the session to export
        # @return [Hash] the serialized request payload
        def request_payload(session)
          serialize_request(session)
        end

        # Parse a response from the target format into an PromptBuilder::Response.
        #
        # @param hash [Hash] the response hash in the target format
        # @return [Response] the parsed response
        def parse_response(hash)
          deserialize_response(hash)
        end

        private

        def serialize_request(_session)
          raise NotImplementedError
        end

        def deserialize_response(_hash)
          raise NotImplementedError
        end
      end
    end
  end
end
