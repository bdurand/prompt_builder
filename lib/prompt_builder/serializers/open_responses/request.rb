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

              if item["type"] == "function_call_output" && item["output"].is_a?(Array)
                transform_content_blocks!(item["output"])
              else
                content = item["content"]
                transform_content_blocks!(content) if content.is_a?(Array)
              end
            end
          end

          def transform_content_blocks!(blocks)
            blocks.each_with_index do |block, idx|
              next unless block.is_a?(Hash) && block["type"] == "input_image"

              if block["image_url"] || block["file_id"]
                # The canonical model can carry stray data/media_type alongside
                # image_url/file_id; the Open Responses API doesn't define them.
                if block.key?("data") || block.key?("media_type")
                  blocks[idx] = block.except("data", "media_type")
                end
                next
              end

              data = block["data"]
              unless data
                raise UnsupportedFormatError,
                  "Open Responses format requires InputImage.image_url, InputImage.file_id, or InputImage.data"
              end

              media_type = block["media_type"]
              unless media_type
                raise UnsupportedFormatError,
                  "Open Responses format requires InputImage.media_type when using base64 InputImage.data"
              end

              blocks[idx] = block
                .except("data", "media_type")
                .merge("image_url" => "data:#{media_type};base64,#{data}")
            end
          end
        end
      end
    end
  end
end
