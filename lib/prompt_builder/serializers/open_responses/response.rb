# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class OpenResponses < Base
      # Response parser for the OpenAI Open Responses API format.
      class Response < Base
        class << self
          private

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
