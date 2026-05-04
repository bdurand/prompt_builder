# frozen_string_literal: true

require "json"

module PromptBuilder
  module Serializers
    class Gemini < Base
      # Request serializer for the Google Gemini API format.
      #
      # === Unsupported Open Responses features
      #
      # These session fields are not supported and raise +UnsupportedFormatError+:
      # - +background+ — Gemini has no background/async mode on the generate endpoint
      # - +frequency_penalty+ — not supported by the Gemini generation API
      # - +include+ — response-field inclusion is an Open Responses-only concept
      # - +max_tool_calls+ — per-request tool-call caps are not supported
      # - +metadata+ — arbitrary metadata is not supported
      # - +parallel_tool_calls+ — parallel tool call control is not supported
      # - +presence_penalty+ — not supported by the Gemini generation API
      # - +prompt_cache_key+ — explicit prompt cache keys are not supported
      # - +safety_identifier+ — no equivalent user-safety field on the generate endpoint
      # - +service_tier+ — service tier selection is not supported
      # - +store+ — server-side response storage is not supported
      # - +stream_options+ — stream event options are not supported
      # - +top_logprobs+ — log probability output is not supported
      # - +truncation+ — server-side context truncation is not supported
      #
      # Input content restrictions:
      # - +InputImage+ content is only supported in user messages (not assistant)
      # - +InputImage+ with +image_url+ requires either base64 +data+ or a Files API /
      #   Cloud Storage URI (+gs://+, +https://generativelanguage.googleapis.com/+);
      #   arbitrary public URLs are not fetched by Gemini and are rejected
      # - +InputFile+ content is only supported in user messages (not assistant)
      # - +InputFile+ requires +media_type+ when +file_data+ is provided, or a
      #   recognized extension on +filename+ / +file_url+
      # - +InputVideo+ requires +video_url+ (only URL-based video is supported)
      # - +RefusalContent+ is dropped silently (a parsed Chat Completions
      #   refusal can stay in session history without breaking subsequent
      #   request_payload calls)
      # - +redacted_thinking+ reasoning blocks are not supported
      # - +Reasoning+ items with +summary+ blocks are not supported
      # - +FunctionCallOutput+ array contents must be text-only
      # - +Compaction+ and +ItemReference+ items are not supported
      #
      # === Features in Gemini not available through Open Responses
      #
      # The following Gemini parameters cannot be set through the Open Responses
      # canonical format:
      # - +thinkingConfig.thinkingBudget+ — use +reasoning.budget_tokens+ instead
      # - +topK+ — top-K sampling parameter
      # - +seed+ — for reproducible outputs (model-dependent)
      # - +stopSequences+ — custom stop sequences
      # - +candidateCount+ — requesting multiple response candidates
      # - +safetySettings+ — configurable harm-category safety thresholds
      # - Video metadata controls (+videoMetadata+ offset, FPS)
      # - Audio input (model-dependent)
      # - Named cached content resources
      class Request < Base
        SUPPORTED_TEXT_KEYS = %w[format].freeze
        SUPPORTED_REASONING_KEYS = %w[budget_tokens].freeze

        FILE_EXTENSION_MIME_TYPES = {
          "pdf" => "application/pdf",
          "txt" => "text/plain",
          "md" => "text/markdown",
          "markdown" => "text/markdown",
          "html" => "text/html",
          "htm" => "text/html",
          "csv" => "text/csv",
          "json" => "application/json",
          "xml" => "application/xml",
          "rtf" => "application/rtf"
        }.freeze
        private_constant :FILE_EXTENSION_MIME_TYPES

        GOOGLE_FILE_URL_PREFIXES = [
          "gs://",
          "https://generativelanguage.googleapis.com/",
          "https://storage.googleapis.com/"
        ].freeze
        private_constant :GOOGLE_FILE_URL_PREFIXES

        class << self
          private

          def serialize_request(session)
            validate_supported_session_fields!(session)

            h = {}
            raise UnsupportedFormatError, "Gemini format requires session.model" unless session.model

            h["model"] = session.model

            system_instruction = build_system_instruction(session)
            h["systemInstruction"] = system_instruction if system_instruction

            h["contents"] = build_contents(session)

            generation_config = build_generation_config(session)
            h["generationConfig"] = generation_config unless generation_config.empty?

            tools = build_tools(session)
            h["tools"] = tools unless tools.empty?

            tool_config = build_tool_config(session.tool_choice, tools: tools)
            h["toolConfig"] = tool_config if tool_config

            # Gemini selects streaming via endpoint (:streamGenerateContent)
            # rather than a request body field, so session.stream is a no-op
            # at the payload level.

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
            unsupported_fields << "presence_penalty" if session.presence_penalty
            unsupported_fields << "frequency_penalty" if session.frequency_penalty
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

            # Map call_id -> function name so we can resolve a FunctionCallOutput's
            # name field (Gemini's functionResponse requires the function name, not
            # the call id) without a quadratic scan per output.
            call_id_to_name = {}
            session.items.each do |item|
              call_id_to_name[item.call_id] = item.name if item.is_a?(Items::FunctionCall)
            end

            session.items.each do |item|
              case item
              when Items::Message
                next if item.role == "system" || item.role == "developer"

                role = (item.role == "assistant") ? "model" : "user"
                # RefusalContent is dropped silently; it can appear in history
                # via a parsed Chat Completions response but cannot be sent.
                visible_content = item.content.reject { |c| c.is_a?(Content::RefusalContent) }
                next if visible_content.empty?
                parts = visible_content.map { |content| serialize_content(content, role: role) }
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
                function_name = call_id_to_name[item.call_id] || item.call_id

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
                unless item.summary.empty?
                  raise UnsupportedFormatError,
                    "Gemini format cannot serialize Reasoning summary blocks; " \
                    "Gemini requires thinking content blocks (use a Reasoning item produced by the Gemini API)"
                end

                thought_parts = item.content.map { |block| serialize_thinking_block(block) }
                raw_contents << {"role" => "model", "parts" => thought_parts} unless thought_parts.empty?
              when Items::Compaction
                raise UnsupportedFormatError, "Gemini format does not support Compaction items"
              when Items::ItemReference
                raise UnsupportedFormatError, "Gemini format does not support ItemReference items"
              end
            end

            merge_consecutive_contents(raw_contents)
          end

          def serialize_thinking_block(block)
            case block["type"]
            when "thinking"
              part = {"thought" => true, "text" => block.fetch("thinking", "")}
              part["thoughtSignature"] = block["signature"] if block["signature"]
              part
            when "redacted_thinking"
              raise UnsupportedFormatError,
                "Gemini format does not support redacted_thinking blocks"
            else
              raise UnsupportedFormatError,
                "Gemini format does not support reasoning block type #{block["type"].inspect}"
            end
          end

          def serialize_function_output(output)
            if output.is_a?(Array)
              output.map do |content|
                case content
                when Content::InputText, Content::OutputText
                  content.text
                else
                  raise UnsupportedFormatError,
                    "#{content.class.name.split("::").last} is not supported in tool output in Gemini format"
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

              serialize_image(content)
            when Content::InputFile
              if role == "model"
                raise UnsupportedFormatError,
                  "Gemini format does not support assistant InputFile content"
              end

              serialize_file(content)
            when Content::InputVideo
              if role == "model"
                raise UnsupportedFormatError,
                  "Gemini format does not support assistant InputVideo content"
              end

              unless content.video_url
                raise UnsupportedFormatError,
                  "Gemini format requires InputVideo.video_url"
              end

              mime = video_mime_type(content.video_url)
              {"fileData" => {"mimeType" => mime, "fileUri" => content.video_url}}
            when Content::RefusalContent
              # Filtered out before reaching here; defensive no-op.
              nil
            else
              raise UnsupportedFormatError, "Unsupported content type: #{content.class}"
            end
          end

          def serialize_image(content)
            if content.file_id
              return {"fileData" => {"mimeType" => content.media_type || "image/jpeg", "fileUri" => content.file_id}}
            end

            if content.image_url
              unless google_file_uri?(content.image_url)
                raise UnsupportedFormatError,
                  "Gemini format does not support arbitrary public image URLs; use base64 InputImage.data, " \
                  "an InputImage.file_id, or a gs:// / Files API InputImage.image_url"
              end

              return {"fileData" => {"mimeType" => content.media_type || "image/jpeg", "fileUri" => content.image_url}}
            end

            if content.data
              unless content.media_type
                raise UnsupportedFormatError,
                  "Gemini format requires InputImage.media_type for base64 image content"
              end

              return {"inlineData" => {"mimeType" => content.media_type, "data" => content.data}}
            end

            raise UnsupportedFormatError,
              "Gemini format requires InputImage.image_url, InputImage.data, or InputImage.file_id"
          end

          def serialize_file(content)
            if content.file_id
              mime = content.media_type
              unless mime
                raise UnsupportedFormatError,
                  "Gemini format requires InputFile.media_type when using InputFile.file_id"
              end

              return {"fileData" => {"mimeType" => mime, "fileUri" => content.file_id}}
            end

            if content.file_url
              unless google_file_uri?(content.file_url)
                raise UnsupportedFormatError,
                  "Gemini format does not support arbitrary public file URLs; use base64 InputFile.file_data, " \
                  "an InputFile.file_id, or a gs:// / Files API InputFile.file_url"
              end

              mime = content.media_type || file_mime_type(content)
              unless mime
                raise UnsupportedFormatError,
                  "Gemini format requires InputFile.media_type or a recognized filename extension for gs:// or Files API URLs"
              end

              return {"fileData" => {"mimeType" => mime, "fileUri" => content.file_url}}
            end

            if content.file_data
              mime = content.media_type || file_mime_type(content)
              unless mime
                raise UnsupportedFormatError,
                  "Gemini format requires InputFile.media_type or a recognized filename extension for base64 file content"
              end

              return {"inlineData" => {"mimeType" => mime, "data" => content.file_data}}
            end

            raise UnsupportedFormatError,
              "Gemini format requires InputFile.file_url, InputFile.file_data, or InputFile.file_id"
          end

          def google_file_uri?(uri)
            GOOGLE_FILE_URL_PREFIXES.any? { |prefix| uri.start_with?(prefix) }
          end

          def file_mime_type(content)
            [content.filename, content.file_url].each do |path|
              next unless path

              ext = File.extname(path).delete_prefix(".").downcase
              mime = FILE_EXTENSION_MIME_TYPES[ext]
              return mime if mime
            end
            nil
          end

          def video_mime_type(video_url)
            ext = File.extname(video_url).delete_prefix(".").downcase
            case ext
            when "mp4" then "video/mp4"
            when "mov" then "video/quicktime"
            when "webm" then "video/webm"
            when "mkv" then "video/x-matroska"
            when "mpeg", "mpg" then "video/mpeg"
            when "flv" then "video/x-flv"
            when "wmv" then "video/x-ms-wmv"
            when "3gp" then "video/3gpp"
            else "video/mp4"
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
            config["topP"] = session.top_p if session.top_p
            config["maxOutputTokens"] = session.max_output_tokens if session.max_output_tokens

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
                  config["responseMimeType"] = "application/json"
                when "json_schema"
                  config["responseMimeType"] = "application/json"
                  schema = format.dig("json_schema", "schema") || format["schema"]
                  config["responseSchema"] = schema if schema
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
                config["thinkingConfig"] = {"thinkingBudget" => session.reasoning["budget_tokens"]}
              end
            end

            config
          end

          def build_tools(session)
            return [] if session.tool_definitions.empty?

            [
              {
                "functionDeclarations" => session.tool_definitions.map do |definition|
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
              config["functionCallingConfig"] = {"mode" => "AUTO"}
            when "none"
              config["functionCallingConfig"] = {"mode" => "NONE"}
            when "required"
              config["functionCallingConfig"] = {"mode" => "ANY"}
            when Hash
              if tool_choice["type"] == "function"
                name = tool_choice["name"] || tool_choice.dig("function", "name")
                unless name
                  raise UnsupportedFormatError,
                    "Gemini format requires tool_choice.name for function tool choices"
                end

                config["functionCallingConfig"] = {
                  "mode" => "ANY",
                  "allowedFunctionNames" => [name]
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
