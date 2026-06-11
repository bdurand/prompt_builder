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

        # Ensure a response payload is a Hash containing the key that identifies
        # it as a well-formed response for this format. Raised before parsing so
        # malformed bodies (e.g. provider error envelopes) fail loudly with the
        # offending body rather than producing a silently empty Response.
        #
        # @param hash [Object] the raw response payload
        # @param key [String] a key that must be present in a valid payload
        # @raise [UnexpectedPayloadError] if the key is missing
        def require_response_key!(hash, key)
          return if hash.is_a?(Hash) && hash.key?(key)

          raise UnexpectedPayloadError,
            "unexpected response payload, missing #{key.inspect}: #{hash.inspect}"
        end
      end
    end
  end
end
