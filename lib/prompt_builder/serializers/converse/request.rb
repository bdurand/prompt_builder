# frozen_string_literal: true

require "json"
require "securerandom"

module PromptBuilder
  module Serializers
    class Converse < Base
      # Request serializer for the Amazon Bedrock Converse API format.
      #
      # === Unsupported Open Responses features
      #
      # These session fields are not supported and raise +UnsupportedFormatError+:
      # - +background+ — background/async mode is not supported on the Converse endpoint
      # - +frequency_penalty+ — not supported by the Converse API
      # - +include+ — response-field inclusion is an Open Responses-only concept
      # - +max_tool_calls+ — per-request tool-call caps are not supported
      # - +metadata+ — arbitrary metadata is not supported on the Converse endpoint
      # - +parallel_tool_calls+ — parallel tool call control is not supported
      # - +presence_penalty+ — not supported by the Converse API
      # - +prompt_cache_key+ — explicit prompt cache keys are not supported
      # - +reasoning+ — extended thinking is not supported on the Converse endpoint
      # - +safety_identifier+ — no equivalent user-safety field on the Converse endpoint
      # - +service_tier+ — service tier selection is not supported
      # - +store+ — server-side response storage is not supported
      # - +stream+ — SSE streaming is handled outside the Converse request payload
      # - +stream_options+ — stream event options are not supported
      # - +text+ — structured response format control is not supported
      # - +top_logprobs+ — log probability output is not supported
      # - +truncation+ — server-side context truncation is not supported
      #
      # Tool choice restrictions:
      # - +tool_choice: "none"+ is not supported by the Converse API
      #
      # Input content restrictions:
      # - +Reasoning+ items are not supported
      # - +RefusalContent+ is dropped silently (a parsed Chat Completions
      #   refusal can stay in session history without breaking subsequent
      #   request_payload calls)
      # - +InputImage+ content is only supported in user messages (not assistant)
      # - +InputFile+ content is only supported in user messages (not assistant)
      # - +InputVideo+ content is only supported in user messages (not assistant)
      # - +InputImage+ requires base64 +data+ or an S3 URI (+s3://...+) — public URLs
      #   are not accepted
      # - +InputFile+ requires base64 +file_data+ or an S3 URI — public URLs are not
      #   accepted; format is detected from the filename or +file_url+ extension
      # - +InputVideo+ requires an S3 URI (+s3://...+) — public URLs are not accepted
      # - Only text and image content is supported in tool (+FunctionCallOutput+) results
      #
      # === Features in Converse not available through Open Responses
      #
      # The following Converse parameters cannot be set through the Open Responses
      # canonical format:
      # - +stopSequences+ — custom stop sequences
      # - Guardrail policies (+guardrailConfig+)
      # - Guardrail trace and assessment events
      # - Per-model passthrough fields (+additionalModelRequestFields+)
      # - Cross-region routing via inference profiles
      # - +performanceConfig+ (service tier / latency tier selection)
      # - +requestMetadata+ (request metadata / safety identifier)
      # - Latency metrics in the response body
      class Request < Base
        IMAGE_MEDIA_TYPE_FORMATS = {
          "image/jpeg" => "jpeg",
          "image/jpg" => "jpeg",
          "image/png" => "png",
          "image/gif" => "gif",
          "image/webp" => "webp"
        }.freeze

        IMAGE_URL_EXTENSION_FORMATS = {
          "jpg" => "jpeg",
          "jpeg" => "jpeg",
          "png" => "png",
          "gif" => "gif",
          "webp" => "webp"
        }.freeze

        DOCUMENT_FILENAME_EXTENSION_FORMATS = {
          "pdf" => "pdf",
          "csv" => "csv",
          "doc" => "doc",
          "docx" => "docx",
          "xls" => "xls",
          "xlsx" => "xlsx",
          "html" => "html",
          "htm" => "html",
          "txt" => "txt",
          "md" => "md",
          "markdown" => "md"
        }.freeze

        VIDEO_URL_EXTENSION_FORMATS = {
          "mkv" => "mkv",
          "mov" => "mov",
          "mp4" => "mp4",
          "webm" => "webm",
          "flv" => "flv",
          "mpeg" => "mpeg",
          "mpg" => "mpeg",
          "wmv" => "wmv",
          "3gp" => "three_gp"
        }.freeze

        class << self
          private

          def serialize_request(session)
            validate_supported_session_fields!(session)

            # document_name_counts is scoped per request (passed through the
            # build chain) so concurrent serializations don't share counter state.
            ctx = {document_name_counts: Hash.new(0)}

            h = {}
            h["modelId"] = session.model if session.model

            system = build_system(session)
            h["system"] = system unless system.empty?

            messages = build_messages(session, ctx)
            if messages.empty?
              raise UnsupportedFormatError,
                "Converse format requires at least one user/assistant message"
            end
            unless messages.first["role"] == "user"
              raise UnsupportedFormatError,
                "Converse format requires the first message to have role \"user\""
            end
            h["messages"] = messages

            inference_config = build_inference_config(session)
            h["inferenceConfig"] = inference_config unless inference_config.empty?

            tool_config = build_tool_config(session)
            h["toolConfig"] = tool_config if tool_config

            h
          end

          def validate_supported_session_fields!(session)
            unsupported_fields = []
            unsupported_fields << "include" if session.include
            unsupported_fields << "presence_penalty" if session.presence_penalty
            unsupported_fields << "frequency_penalty" if session.frequency_penalty
            unsupported_fields << "stream" unless session.stream.nil?
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
            unsupported_fields << "text" if session.text
            unsupported_fields << "reasoning" if session.reasoning

            return if unsupported_fields.empty?

            raise UnsupportedFormatError,
              "Converse format does not support session fields: #{unsupported_fields.join(", ")}"
          end

          def build_system(session)
            parts = []

            parts << {"text" => session.instructions} if session.instructions

            session.items.each do |item|
              next unless item.is_a?(Items::Message)
              next unless item.role == "system" || item.role == "developer"

              item.content.each do |content|
                parts << {"text" => content.text} if content.is_a?(Content::InputText)
              end
            end

            parts
          end

          def build_messages(session, ctx)
            raw_messages = []

            session.items.each do |item|
              case item
              when Items::Message
                next if item.role == "system" || item.role == "developer"

                role = (item.role == "assistant") ? "assistant" : "user"
                # RefusalContent is dropped silently; it can land in history via
                # a parsed Chat Completions response but cannot be sent back.
                visible_content = item.content.reject { |c| c.is_a?(Content::RefusalContent) }
                next if visible_content.empty?
                content = visible_content.map { |c| serialize_content(c, role: role, ctx: ctx) }
                raw_messages << {"role" => role, "content" => content}
              when Items::FunctionCall
                raw_messages << {
                  "role" => "assistant",
                  "content" => [{
                    "toolUse" => {
                      "toolUseId" => item.call_id,
                      "name" => item.name,
                      "input" => parse_tool_use_input(item)
                    }
                  }]
                }
              when Items::FunctionCallOutput
                raw_messages << {
                  "role" => "user",
                  "content" => [serialize_tool_result(item, ctx)]
                }
              when Items::Reasoning
                raise UnsupportedFormatError, "Converse format does not support Reasoning items"
              when Items::Compaction
                raise UnsupportedFormatError, "Converse format does not support Compaction items"
              when Items::ItemReference
                raise UnsupportedFormatError, "Converse format does not support ItemReference items"
              end
            end

            merge_consecutive_messages(raw_messages)
          end

          # Bedrock toolUse.input must be a JSON object. Wrap parser errors as
          # UnsupportedFormatError and reject non-object JSON values.
          def parse_tool_use_input(item)
            parsed = item.parsed_arguments
            unless parsed.is_a?(Hash)
              raise UnsupportedFormatError,
                "Converse format requires FunctionCall arguments to be a JSON object"
            end
            parsed
          rescue PromptBuilder::InvalidItemError => e
            raise UnsupportedFormatError,
              "Converse format could not parse FunctionCall arguments: #{e.message}"
          end

          def serialize_content(content, role:, ctx: nil)
            case content
            when Content::InputText, Content::OutputText
              {"text" => content.text}
            when Content::InputImage
              if role == "assistant"
                raise UnsupportedFormatError,
                  "Converse format does not support assistant InputImage content"
              end

              serialize_image(content)
            when Content::InputFile
              if role == "assistant"
                raise UnsupportedFormatError,
                  "Converse format does not support assistant InputFile content"
              end

              serialize_document(content, ctx)
            when Content::InputVideo
              if role == "assistant"
                raise UnsupportedFormatError,
                  "Converse format does not support assistant InputVideo content"
              end

              serialize_video(content)
            when Content::RefusalContent
              # Filtered out before reaching here; defensive no-op.
              nil
            else
              raise UnsupportedFormatError, "Unsupported content type: #{content.class}"
            end
          end

          def serialize_image(content)
            format = detect_image_format(content)
            source = if content.data
              {"bytes" => content.data}
            elsif content.image_url&.start_with?("s3://")
              {"s3Location" => {"uri" => content.image_url}}
            else
              raise UnsupportedFormatError,
                "Converse format requires InputImage.data or an S3 URI for InputImage.image_url"
            end

            {"image" => {"format" => format, "source" => source}}
          end

          def detect_image_format(content)
            if content.media_type
              format = IMAGE_MEDIA_TYPE_FORMATS[content.media_type]
              return format if format
            end

            url = content.image_url
            if url
              ext = File.extname(url).delete_prefix(".").downcase
              format = IMAGE_URL_EXTENSION_FORMATS[ext]
              return format if format
            end

            raise UnsupportedFormatError,
              "Converse format could not detect image format; set InputImage.media_type (e.g. \"image/jpeg\")"
          end

          DOCUMENT_MEDIA_TYPE_FORMATS = {
            "application/pdf" => "pdf",
            "text/csv" => "csv",
            "application/msword" => "doc",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
            "application/vnd.ms-excel" => "xls",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
            "text/html" => "html",
            "text/plain" => "txt",
            "text/markdown" => "md"
          }.freeze

          def serialize_document(content, ctx)
            format = detect_document_format(content)
            source = if content.file_data
              {"bytes" => content.file_data}
            elsif content.file_url&.start_with?("s3://")
              {"s3Location" => {"uri" => content.file_url}}
            else
              raise UnsupportedFormatError,
                "Converse format requires InputFile.file_data or an S3 URI for InputFile.file_url"
            end

            name = document_name(content, ctx)
            {"document" => {"format" => format, "name" => name, "source" => source}}
          end

          def detect_document_format(content)
            if content.media_type
              format = DOCUMENT_MEDIA_TYPE_FORMATS[content.media_type]
              return format if format
            end

            [content.filename, content.file_url].each do |path|
              next unless path

              ext = File.extname(path).delete_prefix(".").downcase
              format = DOCUMENT_FILENAME_EXTENSION_FORMATS[ext]
              return format if format
            end

            raise UnsupportedFormatError,
              "Converse format could not detect document format; set InputFile.media_type or a recognized file extension on InputFile.filename or InputFile.file_url"
          end

          # Bedrock requires document.name to be unique within a request and to
          # match /^[A-Za-z0-9 \-\(\)\[\]]{1,256}$/. Prefer the filename, fall
          # back to the file_url basename, then a random suffix to avoid
          # collisions when multiple unnamed documents are attached. The counter
          # state lives on the per-request `ctx` Hash so concurrent calls don't
          # share state.
          def document_name(content, ctx)
            source = content.filename || content.file_url
            candidate = nil

            if source
              base = File.basename(source, ".*")
              sanitized = base.gsub(/[^A-Za-z0-9 \-()\[\]]/, "-")
              candidate = sanitized[0, 256]
              candidate = nil if candidate.empty?
            end

            candidate ||= "document-#{SecureRandom.hex(4)}"

            counts = ctx[:document_name_counts]
            counts[candidate] += 1

            return candidate if counts[candidate] == 1

            suffix = "-#{counts[candidate]}"
            "#{candidate[0, 256 - suffix.length]}#{suffix}"
          end

          def serialize_video(content)
            unless content.video_url
              raise UnsupportedFormatError,
                "Converse format requires InputVideo.video_url"
            end

            unless content.video_url.start_with?("s3://")
              raise UnsupportedFormatError,
                "Converse format requires an S3 URI for InputVideo.video_url"
            end

            ext = File.extname(content.video_url).delete_prefix(".").downcase
            format = VIDEO_URL_EXTENSION_FORMATS[ext]

            unless format
              raise UnsupportedFormatError,
                "Converse format could not detect video format from InputVideo.video_url extension"
            end

            {"video" => {"format" => format, "source" => {"s3Location" => {"uri" => content.video_url}}}}
          end

          def serialize_tool_result(item, _ctx)
            result = {"toolUseId" => item.call_id}

            status = converse_tool_result_status(item.status)
            result["status"] = status if status

            content = if item.output.is_a?(Array)
              item.output.map { |c| serialize_tool_result_content(c) }
            elsif !item.output.nil? && !item.output.empty?
              [{"text" => item.output}]
            else
              []
            end

            # Bedrock requires toolResult.content to be a non-empty array.
            content = [{"text" => ""}] if content.empty?
            result["content"] = content

            {"toolResult" => result}
          end

          # Bedrock toolResult.status only accepts "success" or "error". Map
          # Open Responses-style status values to that shape; pass through
          # already-valid values; ignore everything else.
          def converse_tool_result_status(status)
            case status
            when nil, ""
              nil
            when "success", "error"
              status
            when "failed", "incomplete"
              "error"
            when "completed"
              "success"
            end
          end

          def serialize_tool_result_content(content)
            case content
            when Content::InputText, Content::OutputText
              {"text" => content.text}
            when Content::InputImage
              serialize_image(content)
            else
              raise UnsupportedFormatError,
                "#{content.class.name.split("::").last} is not supported in tool output in Converse format"
            end
          end

          def merge_consecutive_messages(messages)
            return messages if messages.empty?

            merged = [messages.first]

            messages[1..].each do |message|
              if merged.last["role"] == message["role"]
                merged.last["content"].concat(message["content"])
              else
                merged << message
              end
            end

            merged
          end

          def build_inference_config(session)
            config = {}
            config["maxTokens"] = session.max_output_tokens if session.max_output_tokens
            config["temperature"] = session.temperature if session.temperature
            config["topP"] = session.top_p if session.top_p
            config
          end

          def build_tool_config(session)
            tools = build_tools(session)
            return nil if tools.empty? && session.tool_choice.nil?

            config = {}
            config["tools"] = tools unless tools.empty?
            config["toolChoice"] = serialize_tool_choice(session.tool_choice, tools.empty?) if session.tool_choice

            config
          end

          def build_tools(session)
            session.tool_definitions.map do |definition|
              tool_spec = {"name" => definition.name}
              tool_spec["description"] = definition.description if definition.description
              tool_spec["inputSchema"] = {
                "json" => definition.parameters || {"type" => "object", "properties" => {}}
              }
              {"toolSpec" => tool_spec}
            end
          end

          def serialize_tool_choice(choice, tools_empty)
            if tools_empty
              raise UnsupportedFormatError,
                "Converse format does not support tool_choice without tools"
            end

            case choice
            when "auto"
              {"auto" => {}}
            when "required"
              {"any" => {}}
            when "none"
              raise UnsupportedFormatError,
                "Converse format does not support tool_choice 'none'"
            when Hash
              if choice["type"] == "function"
                name = choice["name"] || choice.dig("function", "name")
                unless name
                  raise UnsupportedFormatError,
                    "Converse format requires tool_choice.name for function tool choices"
                end

                {"tool" => {"name" => name}}
              else
                raise UnsupportedFormatError,
                  "Converse format does not support tool_choice #{choice.inspect}"
              end
            else
              raise UnsupportedFormatError,
                "Converse format does not support tool_choice #{choice.inspect}"
            end
          end
        end
      end
    end
  end
end
