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
        # @param headers [Hash, #each, nil] the HTTP response headers, for
        #   formats that return response metadata in headers rather than in
        #   the body
        # @return [Response] the parsed response
        # @raise [ErrorResponseError] if the payload is an API error envelope
        def parse_response(hash, headers: nil)
          check_error_response!(hash)
          deserialize_response(hash, headers)
        end

        private

        def serialize_request(_session)
          raise NotImplementedError
        end

        def deserialize_response(_hash, _headers = nil)
          raise NotImplementedError
        end

        # Detect API error envelopes before parsing so errors surface with the
        # message reported by the API instead of the generic missing-key error
        # from require_response_key!. Serializer response classes override
        # error_response_message to recognize their format's error envelope.
        #
        # @param hash [Object] the raw response payload
        # @return [void]
        # @raise [ErrorResponseError] if the payload is an API error envelope
        def check_error_response!(hash)
          return unless hash.is_a?(Hash)

          message = error_response_message(hash)
          return if message.nil? || message.empty?

          raise ErrorResponseError, "the API returned an error: #{message}"
        end

        # Extract a human-readable message from an API error envelope.
        #
        # @param _hash [Hash] the raw response payload
        # @return [String, nil] nil when the payload is not recognized as an
        #   error envelope
        def error_response_message(_hash)
          nil
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

          body = JSON.generate(hash)[0..200]
          raise UnexpectedPayloadError,
            "unexpected response payload, missing #{key.inspect}: #{body}"
        end
      end
    end
  end
end
