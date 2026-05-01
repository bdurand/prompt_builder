# frozen_string_literal: true

require "json"

module PromptBuilder
  module Serializers
    class Gemini < Base
      # Request serializer for the Google Gemini API format.
      class Request < Base
        SUPPORTED_TEXT_KEYS = %w[format].freeze
        SUPPORTED_REASONING_KEYS = %w[budget_tokens].freeze

        class << self
          private

          def serialize_request(session)
            validate_supported_session_fields!(session)

            h = {}
            raise UnsupportedFormatError, "Gemini format requires session.model" unless session.model

            h["model"] = session.model

            system_instruction = build_system_instruction(session)
            h["system_instruction"] = system_instruction if system_instruction

            h["contents"] = build_contents(session)

            generation_config = build_generation_config(session)
            h["generation_config"] = generation_config unless generation_config.empty?

            tools = build_tools(session)
            h["tools"] = tools unless tools.empty?

            tool_config = build_tool_config(session.tool_choice, tools: tools)
            h["tool_config"] = tool_config if tool_config

            h["stream"] = session.stream unless session.stream.nil?

            h
          end

          def validate_supported_session_fields!(session)
            unsupported_fields = []
            unsupported_fields << "include" if session.include
            unsupported_fields << "stream_options" if session.stream_options
            unsupported_fields << "background" unless session.background.nil?
            unsupported_fields << "max_tool_calls" if session.max_tool_calls
            unsupported_fields << "safety_identifier" if session.safety_identifier
            unsupported_fields << "prompt_cache_key" if session.prompt_cache_key
            unsupported_fields << "truncation" if session.truncation
            unsupported_fields << "store" unless session.store.nil?
            unsupported_fields << "top_logprobs" if session.top_logprobs
            unsupported_fields << "service_tier" if session.service_tier
            unsupported_fields << "metadata" if session.metadata
            unsupported_fields << "parallel_tool_calls" unless session.parallel_tool_calls.nil?

            return if unsupported_fields.empty?

            raise UnsupportedFormatError,
              "Gemini format does not support session fields: #{unsupported_fields.join(", ")}"
          end

          def build_system_instruction(session)
            parts = []

            if session.instructions
              parts << {"text" => session.instructions}
            end

            session.items.each do |item|
              next unless item.is_a?(Items::Message)
              next unless item.role == "system" || item.role == "developer"

              item.content.each do |content|
                parts << {"text" => content.text} if content.is_a?(Content::InputText)
              end
            end

            return nil if parts.empty?

            {"parts" => parts}
          end

          def build_contents(session)
            raw_contents = []

            # Build a lookup map for function call names by index
            function_call_map = {}
            session.items.each_with_index do |item, idx|
              if item.is_a?(Items::FunctionCall)
                function_call_map[idx] = item.name
              end
            end

            session.items.each_with_index do |item, idx|
              case item
              when Items::Message
                next if item.role == "system" || item.role == "developer"

                role = (item.role == "assistant") ? "model" : "user"
                parts = item.content.map { |content| serialize_content(content, role: role) }
                raw_contents << {"role" => role, "parts" => parts}
              when Items::FunctionCall
                parts = [{
                  "functionCall" => {
                    "name" => item.name,
                    "args" => item.parsed_arguments
                  }
                }]
                raw_contents << {"role" => "model", "parts" => parts}
              when Items::FunctionCallOutput
                # Find the prior function call to get its name
                prior_call_idx = nil
                session.items[0...idx].each_with_index do |prior_item, prior_idx|
                  if prior_item.is_a?(Items::FunctionCall) && prior_item.call_id == item.call_id
                    prior_call_idx = prior_idx
                  end
                end

                function_name = prior_call_idx ? function_call_map[prior_call_idx] : item.call_id

                parts = [{
                  "functionResponse" => {
                    "name" => function_name,
                    "response" => {
                      "result" => serialize_function_output(item.output)
                    }
                  }
                }]
                raw_contents << {"role" => "user", "parts" => parts}
              when Items::Reasoning
                validate_reasoning!(item)
                item.content.each do |block|
                  next unless block["type"] == "thinking"

                  parts = [{"thought" => true, "text" => block.fetch("thinking", "")}]
                  raw_contents << {"role" => "model", "parts" => parts}
                end
              end
            end

            merge_consecutive_contents(raw_contents)
          end

          def validate_reasoning!(item)
            item.content.each do |block|
              if block["type"] == "thinking" && block["signature"]
                raise UnsupportedFormatError,
                  "Gemini format does not support reasoning blocks with signatures"
              end
              if block["type"] == "redacted_thinking"
                raise UnsupportedFormatError,
                  "Gemini format does not support redacted_thinking blocks"
              end
            end
          end

          def serialize_function_output(output)
            if output.is_a?(Array)
              output.map do |content|
                case content
                when Content::InputText, Content::OutputText
                  content.text
                else
                  content.to_s
                end
              end.join("\n")
            else
              output || ""
            end
          end

          def serialize_content(content, role:)
            case content
            when Content::InputText, Content::OutputText
              {"text" => content.text}
            when Content::InputImage
              if role == "model"
                raise UnsupportedFormatError,
                  "Gemini format does not support assistant InputImage content"
              end

              if content.image_url
                {"fileData" => {"mimeType" => content.media_type || "image/jpeg", "fileUri" => content.image_url}}
              elsif content.data
                unless content.media_type
                  raise UnsupportedFormatError,
                    "Gemini format requires InputImage.media_type for base64 image content"
                end

                {"inlineData" => {"mimeType" => content.media_type, "data" => content.data}}
              else
                raise UnsupportedFormatError,
                  "Gemini format requires InputImage.image_url or InputImage.data"
              end
            when Content::InputFile
              if role == "model"
                raise UnsupportedFormatError,
                  "Gemini format does not support assistant InputFile content"
              end

              mime_type = "application/octet-stream"
              if content.file_url
                {"fileData" => {"mimeType" => mime_type, "fileUri" => content.file_url}}
              elsif content.file_data
                {"inlineData" => {"mimeType" => mime_type, "data" => content.file_data}}
              else
                raise UnsupportedFormatError,
                  "Gemini format requires InputFile.file_url or InputFile.file_data"
              end
            when Content::InputVideo
              if role == "model"
                raise UnsupportedFormatError,
                  "Gemini format does not support assistant InputVideo content"
              end

              unless content.video_url
                raise UnsupportedFormatError,
                  "Gemini format requires InputVideo.video_url"
              end

              {"fileData" => {"mimeType" => "video/mp4", "fileUri" => content.video_url}}
            when Content::RefusalContent
              raise UnsupportedFormatError, "Gemini format does not support RefusalContent"
            else
              raise UnsupportedFormatError, "Unsupported content type: #{content.class}"
            end
          end

          def merge_consecutive_contents(contents)
            return contents if contents.empty?

            merged = [contents.first]

            contents[1..].each do |content|
              if merged.last["role"] == content["role"]
                merged.last["parts"].concat(content["parts"])
              else
                merged << content
              end
            end

            merged
          end

          def build_generation_config(session)
            config = {}

            config["temperature"] = session.temperature if session.temperature
            config["top_p"] = session.top_p if session.top_p
            config["presence_penalty"] = session.presence_penalty if session.presence_penalty
            config["frequency_penalty"] = session.frequency_penalty if session.frequency_penalty
            config["max_output_tokens"] = session.max_output_tokens if session.max_output_tokens

            if session.text
              unsupported_keys = session.text.keys - SUPPORTED_TEXT_KEYS
              unless unsupported_keys.empty?
                raise UnsupportedFormatError,
                  "Gemini format does not support text.#{unsupported_keys.first}"
              end

              format = session.text["format"]
              if format.is_a?(Hash)
                case format["type"]
                when "json_object"
                  config["response_mime_type"] = "application/json"
                when "json_schema"
                  config["response_mime_type"] = "application/json"
                  schema = format.dig("json_schema", "schema") || format["schema"]
                  config["response_schema"] = schema if schema
                end
              end
            end

            if session.reasoning
              unsupported_keys = session.reasoning.keys - SUPPORTED_REASONING_KEYS
              unless unsupported_keys.empty?
                raise UnsupportedFormatError,
                  "Gemini format does not support reasoning.#{unsupported_keys.first}"
              end

              if session.reasoning["budget_tokens"]
                config["thinking_config"] = {"thinking_budget" => session.reasoning["budget_tokens"]}
              end
            end

            config
          end

          def build_tools(session)
            return [] if session.tool_definitions.empty?

            [
              {
                "function_declarations" => session.tool_definitions.map do |definition|
                  tool = {"name" => definition.name}
                  tool["description"] = definition.description if definition.description
                  tool["parameters"] = definition.parameters || {"type" => "object", "properties" => {}}
                  tool
                end
              }
            ]
          end

          def build_tool_config(tool_choice, tools:)
            return nil if tool_choice.nil?

            config = {}

            if tools.empty?
              if tool_choice != "none"
                raise UnsupportedFormatError,
                  "Gemini format does not support tool_choice without tools"
              end
            end

            case tool_choice
            when "auto"
              config["function_calling_config"] = {"mode" => "AUTO"}
            when "none"
              config["function_calling_config"] = {"mode" => "NONE"}
            when "required"
              config["function_calling_config"] = {"mode" => "ANY"}
            when Hash
              if tool_choice["type"] == "function"
                unless tool_choice["name"]
                  raise UnsupportedFormatError,
                    "Gemini format requires tool_choice.name for function tool choices"
                end

                config["function_calling_config"] = {
                  "mode" => "ANY",
                  "allowed_function_names" => [tool_choice["name"]]
                }
              else
                raise UnsupportedFormatError,
                  "Gemini format does not support tool_choice #{tool_choice.inspect}"
              end
            else
              raise UnsupportedFormatError,
                "Gemini format does not support tool_choice #{tool_choice.inspect}"
            end

            config
          end
        end
      end
    end
  end
end
