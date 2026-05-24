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
            payload.delete("extra")
            strip_extra(payload)
            strip_non_replayable_reasoning!(payload)
            strip_output_only_fields!(payload)
            normalize_and_validate_input_images!(payload)
            normalize_text_format!(payload)
            payload
          end

          private

          # Walk the payload and remove any "extra" keys from items, content
          # blocks, and tool definitions since they are not part of the Open
          # Responses API schema.
          def strip_extra(payload)
            input = payload["input"]
            if input.is_a?(Array)
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

            tools = payload["tools"]
            strip_extra_from_blocks!(tools) if tools.is_a?(Array)
          end

          def normalize_and_validate_input_images!(payload)
            input = payload["input"]
            return unless input.is_a?(Array)

            input.each_with_index do |item, input_index|
              next unless item.is_a?(Hash)

              if item["type"] == "function_call_output" && item["output"].is_a?(Array)
                normalize_and_validate_image_blocks!(item["output"], "input.#{input_index}.output")
                next
              end

              content = item["content"]
              next unless content.is_a?(Array)

              normalize_and_validate_image_blocks!(content, "input.#{input_index}.content")
            end
          end

          def normalize_and_validate_image_blocks!(blocks, path_prefix)
            blocks.each_with_index do |block, block_index|
              next unless block.is_a?(Hash)
              next unless block["type"] == "input_image"

              image_url = normalize_optional_string(block["image_url"])
              file_id = normalize_optional_string(block["file_id"])

              image_url ? block["image_url"] = image_url : block.delete("image_url")
              file_id ? block["file_id"] = file_id : block.delete("file_id")

              if image_url && file_id
                raise InvalidItemError,
                  "#{path_prefix}.#{block_index} includes both image_url and file_id; provide exactly one"
              end

              next if image_url || file_id

              raise InvalidItemError,
                "#{path_prefix}.#{block_index} requires exactly one of image_url or file_id"
            end
          end

          # Remove reasoning items that cannot be sent back in input.
          # The Responses API only accepts reasoning items with
          # encrypted_content; plain reasoning_text content blocks are
          # output-only and cause an invalid_union error.
          # For preserved reasoning items, strip the content key since
          # the input schema only accepts null for that field.
          def strip_non_replayable_reasoning!(payload)
            input = payload["input"]
            return unless input.is_a?(Array)

            input.reject! do |item|
              item.is_a?(Hash) &&
                item["type"] == "reasoning" &&
                !item["encrypted_content"]
            end

            input.each do |item|
              next unless item.is_a?(Hash) && item["type"] == "reasoning"

              item.delete("content")
            end
          end

          # Remove output-only fields from content blocks that are not
          # accepted by the Responses API input schema.
          # OutputTextContentParam only accepts type, text, and annotations;
          # logprobs is output-only metadata.
          def strip_output_only_fields!(payload)
            input = payload["input"]
            return unless input.is_a?(Array)

            input.each do |item|
              next unless item.is_a?(Hash)

              content = item["content"]
              next unless content.is_a?(Array)

              content.each do |block|
                next unless block.is_a?(Hash) && block["type"] == "output_text"

                block.delete("logprobs")
              end
            end
          end

          def normalize_optional_string(value)
            return value unless value.is_a?(String)

            normalized = value.strip
            normalized.empty? ? nil : normalized
          end

          def strip_extra_from_blocks!(blocks)
            blocks.each do |block|
              next unless block.is_a?(Hash)

              block.delete("extra")
            end
          end

          # Normalize text.format for the Responses API. If the format uses
          # the Chat Completions nested json_schema sub-object, flatten it
          # so name/schema/strict/description sit directly under format.
          def normalize_text_format!(payload)
            format = payload.dig("text", "format")
            return unless format.is_a?(Hash) && format["type"] == "json_schema"

            json_schema = format["json_schema"]
            return unless json_schema.is_a?(Hash)

            format.delete("json_schema")
            json_schema.each { |key, value| format[key] = value }
          end
        end
      end
    end
  end
end
