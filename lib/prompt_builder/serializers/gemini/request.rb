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
      # - +include+ — response-field inclusion is an Open Responses-only concept
      # - +max_tool_calls+ — per-request tool-call caps are not supported
      # - +metadata+ — arbitrary metadata is not supported
      # - +parallel_tool_calls+ — parallel tool call control is not supported
      # - +prompt_cache_key+ / +prompt_cache_retention+ — explicit prompt cache keys are not supported
      # - +safety_identifier+ — no equivalent user-safety field on the generate endpoint
      # - +stream_options+ — stream event options are not supported
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
      # - +thinkingConfig.thinkingLevel+ — use +reasoning.effort+ instead
      # - +thinkingConfig.includeThoughts+ — use +reasoning.summary = "auto"+ instead
      # - +topK+ — top-K sampling parameter
      # - +seed+ — for reproducible outputs (model-dependent)
      # - +stopSequences+ — custom stop sequences
      # - +candidateCount+ — requesting multiple response candidates
      # - +responseModalities+ — selecting TEXT/IMAGE/AUDIO output channels
      # - +responseJsonSchema+ — newer JSON Schema variant of +responseSchema+
      # - +safetySettings+ — configurable harm-category safety thresholds
      # - +mediaResolution+ — controls token cost of image/video inputs
      # - +audioTimestamp+, +speechConfig+ — audio output configuration
      # - +enableEnhancedCivicAnswers+
      # - +routingConfig+, +modelSelectionConfig+
      # - Video metadata controls (+videoMetadata+ offset, FPS) on +Part+s
      # - Audio input model capability controls (audio can be sent as
      #   +InputFile+ with an audio MIME type)
      # - Built-in Gemini tools: +googleSearch+ / +googleSearchRetrieval+,
      #   +codeExecution+, +urlContext+, +computerUse+, +fileSearch+,
      #   +googleMaps+, +mcpServers+
      # - +functionCallingConfig.mode = VALIDATED+
      # - +toolConfig.retrievalConfig+, +includeServerSideToolInvocations+
      # - +cachedContent+ — referencing a CachedContent resource by name
      # - Top-level +labels+ (Vertex flavor only)
      class Request < Base
        SUPPORTED_TEXT_KEYS = %w[format].freeze
        SUPPORTED_REASONING_KEYS = %w[budget_tokens effort summary].freeze
        SUPPORTED_REASONING_EFFORTS = %w[minimal low medium high].freeze
        SUPPORTED_REASONING_SUMMARIES = %w[auto].freeze
        SUPPORTED_SERVICE_TIERS = %w[unspecified standard flex priority].freeze

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
          "rtf" => "application/rtf",
          "png" => "image/png",
          "jpg" => "image/jpeg",
          "jpeg" => "image/jpeg",
          "webp" => "image/webp",
          "heic" => "image/heic",
          "heif" => "image/heif",
          "mp3" => "audio/mpeg",
          "wav" => "audio/wav",
          "aiff" => "audio/aiff",
          "aac" => "audio/aac",
          "ogg" => "audio/ogg",
          "flac" => "audio/flac",
          "mp4" => "video/mp4",
          "mov" => "video/quicktime",
          "webm" => "video/webm",
          "mpeg" => "video/mpeg",
          "mpg" => "video/mpeg"
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
            h["store"] = session.store unless session.store.nil?
            h["serviceTier"] = serialize_service_tier(session.service_tier) if session.service_tier

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
            unsupported_fields << "prompt_cache_retention" if session.prompt_cache_retention
            unsupported_fields << "truncation" if session.truncation
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
                function_call = {
                  "name" => item.name,
                  "args" => parse_function_call_args(item)
                }
                function_call["id"] = item.call_id if item.call_id
                part = {"functionCall" => function_call}
                thought_sig = item.extra && item.extra["thought_signature"]
                part["thoughtSignature"] = thought_sig if thought_sig
                parts = [part]
                raw_contents << {"role" => "model", "parts" => parts}
              when Items::FunctionCallOutput
                function_name = call_id_to_name[item.call_id]
                unless function_name
                  raise UnsupportedFormatError,
                    "Gemini format requires a matching FunctionCall for FunctionCallOutput #{item.call_id.inspect}; " \
                    "Gemini's functionResponse.name must reference a previously-declared tool name"
                end

                function_response = {
                  "name" => function_name,
                  "response" => serialize_function_output(item.output)
                }
                function_response["id"] = item.call_id if item.call_id
                parts = [{"functionResponse" => function_response}]
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

          # Gemini's functionResponse.response is a structured Struct (object).
          # When the tool produced a JSON object, return it directly so callers
          # can roundtrip structured output without lossy stringification; for
          # plain strings or arrays of text, wrap in {"result" => ...} so the
          # response is still a valid object.
          def serialize_function_output(output)
            if output.is_a?(Array)
              text = output.map do |content|
                case content
                when Content::InputText, Content::OutputText
                  content.text
                else
                  raise UnsupportedFormatError,
                    "#{content.class.name.split("::").last} is not supported in tool output in Gemini format"
                end
              end.join("\n")
              {"result" => text}
            else
              raw = output || ""
              if raw.is_a?(String) && !raw.empty?
                begin
                  parsed = JSON.parse(raw)
                  return parsed if parsed.is_a?(Hash)
                rescue JSON::ParserError
                  # fall through to wrapping
                end
              end
              {"result" => raw}
            end
          end

          def parse_function_call_args(item)
            parsed = item.parsed_arguments
            unless parsed.is_a?(Hash)
              raise UnsupportedFormatError,
                "Gemini format requires FunctionCall arguments to be a JSON object"
            end
            parsed
          rescue PromptBuilder::InvalidItemError => e
            raise UnsupportedFormatError,
              "Gemini format could not parse FunctionCall arguments: #{e.message}"
          end

          def serialize_content(content, role:)
            case content
            when Content::InputText, Content::OutputText
              part = {"text" => content.text}
              if content.extra && content.extra["thought_signature"]
                part["thoughtSignature"] = content.extra["thought_signature"]
              end
              part
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

              unless google_file_uri?(content.video_url)
                raise UnsupportedFormatError,
                  "Gemini format does not support arbitrary public video URLs; use a gs:// or " \
                  "Files API InputVideo.video_url"
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
            file_id = content.extra && content.extra["file_id"]
            media_type = content.extra && content.extra["media_type"]

            if file_id
              return {"fileData" => {"mimeType" => media_type || "image/jpeg", "fileUri" => file_id}}
            end

            if content.image_url
              parsed = PromptBuilder.parse_data_url(content.image_url)
              if parsed
                return {"inlineData" => {"mimeType" => parsed[0], "data" => parsed[1]}}
              end

              unless google_file_uri?(content.image_url)
                raise UnsupportedFormatError,
                  "Gemini format does not support arbitrary public image URLs; use a data URL in InputImage.image_url, " \
                  "a file_id in extra, or a gs:// / Files API InputImage.image_url"
              end

              return {"fileData" => {"mimeType" => media_type || "image/jpeg", "fileUri" => content.image_url}}
            end

            raise UnsupportedFormatError,
              "Gemini format requires InputImage.image_url or a file_id in extra"
          end

          def serialize_file(content)
            file_id = content.extra && content.extra["file_id"]
            media_type = content.extra && content.extra["media_type"]

            if file_id
              mime = media_type
              unless mime
                raise UnsupportedFormatError,
                  "Gemini format requires media_type in extra when using file_id in extra"
              end

              return {"fileData" => {"mimeType" => mime, "fileUri" => file_id}}
            end

            if content.file_url
              unless google_file_uri?(content.file_url)
                raise UnsupportedFormatError,
                  "Gemini format does not support arbitrary public file URLs; use base64 InputFile.file_data, " \
                  "a file_id in extra, or a gs:// / Files API InputFile.file_url"
              end

              mime = media_type || file_mime_type(content)
              unless mime
                raise UnsupportedFormatError,
                  "Gemini format requires media_type in extra or a recognized filename extension for gs:// or Files API URLs"
              end

              return {"fileData" => {"mimeType" => mime, "fileUri" => content.file_url}}
            end

            if content.file_data
              mime = media_type || file_mime_type(content)
              unless mime
                raise UnsupportedFormatError,
                  "Gemini format requires media_type in extra or a recognized filename extension for base64 file content"
              end

              return {"inlineData" => {"mimeType" => mime, "data" => content.file_data}}
            end

            raise UnsupportedFormatError,
              "Gemini format requires InputFile.file_url, InputFile.file_data, or file_id in extra"
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
            config["presencePenalty"] = session.presence_penalty if session.presence_penalty
            config["frequencyPenalty"] = session.frequency_penalty if session.frequency_penalty

            if session.top_logprobs
              config["responseLogprobs"] = true
              config["logprobs"] = session.top_logprobs
            end

            if session.text
              unsupported_keys = session.text.keys - SUPPORTED_TEXT_KEYS
              unless unsupported_keys.empty?
                raise UnsupportedFormatError,
                  "Gemini format does not support text.#{unsupported_keys.first}"
              end

              format = session.text["format"]
              if format.is_a?(Hash)
                case format["type"]
                when "text"
                  config["responseMimeType"] = "text/plain"
                when "json_object"
                  config["responseMimeType"] = "application/json"
                when "json_schema"
                  config["responseMimeType"] = "application/json"
                  schema = format.dig("json_schema", "schema") || format["schema"]
                  config["responseSchema"] = schema if schema
                else
                  raise UnsupportedFormatError,
                    "Gemini format does not support text.format type #{format["type"].inspect}"
                end
              end
            end

            if session.reasoning
              unsupported_keys = session.reasoning.keys - SUPPORTED_REASONING_KEYS
              unless unsupported_keys.empty?
                raise UnsupportedFormatError,
                  "Gemini format does not support reasoning.#{unsupported_keys.first}"
              end

              thinking_config = {}

              if session.reasoning["budget_tokens"]
                thinking_config["thinkingBudget"] = session.reasoning["budget_tokens"]
              end

              if session.reasoning["effort"]
                effort = session.reasoning["effort"]
                unless SUPPORTED_REASONING_EFFORTS.include?(effort)
                  raise UnsupportedFormatError,
                    "Gemini format only supports reasoning.effort values minimal, low, medium, and high"
                end

                thinking_config["thinkingLevel"] = effort.upcase
              end

              if session.reasoning["summary"]
                summary = session.reasoning["summary"]
                unless SUPPORTED_REASONING_SUMMARIES.include?(summary)
                  raise UnsupportedFormatError,
                    "Gemini format only supports reasoning.summary value auto"
                end

                thinking_config["includeThoughts"] = true
              end

              config["thinkingConfig"] = thinking_config unless thinking_config.empty?
            end

            config
          end

          def serialize_service_tier(service_tier)
            return service_tier if SUPPORTED_SERVICE_TIERS.include?(service_tier)

            raise UnsupportedFormatError,
              "Gemini format only supports service_tier values unspecified, standard, flex, and priority"
          end

          def build_tools(session)
            return [] if session.tool_definitions.empty?

            strict_definition = session.tool_definitions.find(&:strict)
            if strict_definition
              raise UnsupportedFormatError,
                "Gemini format does not support strict tool definitions"
            end

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
