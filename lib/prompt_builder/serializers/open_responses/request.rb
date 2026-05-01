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
            transform_input_images(payload)
            payload
          end

          private

          # Walk the input array and rewrite any base64 input_image blocks into
          # the data-URL form that the Responses API expects.  The internal
          # Session#to_h format stores base64 images as separate `data` and
          # `media_type` keys, but the API requires exactly one of `image_url`
          # or `file_id`.
          def transform_input_images(payload)
            input = payload["input"]
            return unless input.is_a?(Array)

            input.each do |item|
              next unless item.is_a?(Hash)
              content = item["content"]
              next unless content.is_a?(Array)

              content.each_with_index do |block, idx|
                next unless block.is_a?(Hash) && block["type"] == "input_image"
                next if block["image_url"] || block["file_id"]

                data = block["data"]
                media_type = block["media_type"]
                next unless data && media_type

                content[idx] = block
                  .except("data", "media_type")
                  .merge("image_url" => "data:#{media_type};base64,#{data}")
              end
            end
          end
        end
      end
    end
  end
end
