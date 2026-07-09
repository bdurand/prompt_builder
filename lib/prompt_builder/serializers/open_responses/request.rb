# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class OpenResponses < Base
      # Request serializer for the OpenAI Open Responses API format.
      class Request < Base
        # Content extra keys that are part of the Open Responses API schema and
        # must survive extra-stripping (the canonical content classes have no
        # dedicated attribute for them).
        CANONICAL_EXTRA_KEYS = {
          "input_file" => ["file_id"].freeze,
          "input_image" => ["file_id"].freeze
        }.freeze
        private_constant :CANONICAL_EXTRA_KEYS

        class << self
          # Export a session to Open Responses API request payload.
          #
          # @param session [Session] the session to export
          # @return [Hash] the serialized request payload
          def request_payload(session)
            payload = session.to_h
            items = apply_server_state!(payload, session)
            payload.delete("extra")
            strip_extra(payload, items, session.tool_definitions)
            normalize_content_urls!(payload)
            strip_non_replayable_reasoning!(payload)
            strip_output_only_fields!(payload)
            normalize_and_validate_input_images!(payload)
            normalize_text_format!(payload)
            payload
          end

          private

          # When the session is in server-state mode, replace the full input
          # array with only items added after the last response boundary and
          # include previous_response_id for the API to resolve history.
          # Returns the item objects backing the payload's input array.
          def apply_server_state!(payload, session)
            return session.items if session.local_state?

            payload.delete("input")
            new_items = session.items[session.response_boundary_index..] || []
            payload["input"] = new_items.map(&:to_h) unless new_items.empty?
            new_items
          end

          # Remove provider-specific extra data from items, content blocks, and
          # tool definitions since it is not part of the Open Responses API
          # schema. Items, content blocks, and tool definitions serialize their
          # extras flat into the hash, so the extra keys must be looked up on
          # the backing objects rather than removed as a nested "extra" key.
          def strip_extra(payload, items, tool_definitions)
            input = payload["input"]
            if input.is_a?(Array)
              input.each_with_index do |item_hash, index|
                next unless item_hash.is_a?(Hash)

                item = items[index]
                next unless item

                strip_extra_keys!(item_hash, item.extra)

                case item
                when Items::Message
                  strip_extra_from_blocks!(item_hash["content"], item.content)
                when Items::FunctionCallOutput
                  strip_extra_from_blocks!(item_hash["output"], item.output) if item.output.is_a?(Array)
                end
              end
            end

            tools = payload["tools"]
            if tools.is_a?(Array)
              tools.each_with_index do |tool_hash, index|
                next unless tool_hash.is_a?(Hash)

                definition = tool_definitions[index]
                strip_extra_keys!(tool_hash, definition.extra) if definition
              end
            end
          end

          def strip_extra_from_blocks!(blocks, contents)
            return unless blocks.is_a?(Array)

            blocks.each_with_index do |block, index|
              next unless block.is_a?(Hash)

              content = contents[index]
              next unless content.respond_to?(:extra)

              keep = CANONICAL_EXTRA_KEYS.fetch(block["type"], [])
              strip_extra_keys!(block, content.extra, keep: keep)
            end
          end

          def strip_extra_keys!(hash, extra, keep: [])
            return unless extra.is_a?(Hash)

            extra.each_key do |key|
              # "type" is canonical on every item and content block; an extra
              # named "type" never survives serialization, so deleting it here
              # would corrupt the block.
              next if key == "type"
              next if keep.include?(key)

              hash.delete(key)
            end
          end

          # Convert canonical "url" keys back to Open Responses API keys:
          # input_image "url" -> "image_url"
          # input_file "url" -> "file_url"/"file_data"
          # input_video "url" -> "video_url"
          def normalize_content_urls!(payload)
            input = payload["input"]
            return unless input.is_a?(Array)

            input.each do |item|
              next unless item.is_a?(Hash)

              if item["type"] == "function_call_output" && item["output"].is_a?(Array)
                normalize_url_keys_in_blocks!(item["output"])
                next
              end

              content = item["content"]
              normalize_url_keys_in_blocks!(content) if content.is_a?(Array)
            end
          end

          def normalize_url_keys_in_blocks!(blocks)
            blocks.each do |block|
              next unless block.is_a?(Hash)

              case block["type"]
              when "input_image"
                if block.key?("url")
                  block["image_url"] = block.delete("url")
                end
              when "input_file"
                if block.key?("url")
                  url = block.delete("url")
                  if PromptBuilder.parse_data_url(url)
                    block["file_data"] = url
                  else
                    block["file_url"] = url
                  end
                end
              when "input_video"
                if block.key?("url")
                  block["video_url"] = block.delete("url")
                end
              end
            end
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
