# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class OpenResponses < Base
      # Response parser for the OpenAI Open Responses API format.
      class Response < Base
        class << self
          private

          # Open Responses request errors arrive as a bare {"error" => {...}}
          # envelope. A failed response object also carries an "error" field,
          # but it has a "status" and parses into a failed Response instead.
          def error_response_message(hash)
            error = hash["error"]
            return nil unless error.is_a?(Hash) && !hash.key?("status")

            [error["code"] || error["type"], error["message"]].compact.join(": ")
          end

          def deserialize_response(hash)
            require_response_key!(hash, "status")
            require_response_key!(hash, "object")

            PromptBuilder::Response.from_h(hash)
          end
        end
      end
    end
  end
end
