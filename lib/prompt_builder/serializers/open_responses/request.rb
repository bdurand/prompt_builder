# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class OpenResponses < Base
      # Request serializer for the OpenAI Open Responses API format.
      class Request < Base
        class << self
          # Export a session to Open Responses API request payload.
          #
          # @param session [Session] the session to export
          # @return [Hash] the serialized request payload
          def request_payload(session)
            payload = session.to_h
            strip_extra(payload)
            payload
          end

          private

          # Walk the payload and remove any "extra" keys from items and content
          # blocks since they are not part of the Open Responses API schema.
          def strip_extra(payload)
            input = payload["input"]
            return unless input.is_a?(Array)

            input.each do |item|
              next unless item.is_a?(Hash)

              item.delete("extra")

              if item["type"] == "function_call_output" && item["output"].is_a?(Array)
                strip_extra_from_blocks!(item["output"])
              else
                content = item["content"]
                strip_extra_from_blocks!(content) if content.is_a?(Array)
              end
            end
          end

          def strip_extra_from_blocks!(blocks)
            blocks.each do |block|
              next unless block.is_a?(Hash)

              block.delete("extra")
            end
          end
        end
      end
    end
  end
end
