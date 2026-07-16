# frozen_string_literal: true

require "json"
require "securerandom"

module PromptBuilder
  module Serializers
    class Converse < Base
      # Request serializer for the Amazon Bedrock Converse API format.
      #
      # Required session fields (an UnsupportedFormatError is raised when missing):
      # - +model+ — populates the required +modelId+ parameter
      #
      # === Unsupported Open Responses features
      #
      # These session fields are not supported and are silently omitted from the
      # serialized output:
      # - +background+ — background/async mode is not supported on the Converse endpoint
      # - +frequency_penalty+ — not supported by the Converse API
      # - +include+ — response-field inclusion is an Open Responses-only concept
      # - +max_tool_calls+ — per-request tool-call caps are not supported
      # - +parallel_tool_calls+ — parallel tool call control is not supported
      # - +presence_penalty+ — not supported by the Converse API
      # - +prompt_cache_key+ / +prompt_cache_retention+ — explicit prompt cache keys are not supported
      # - +reasoning+ — extended thinking is not supported on the Converse endpoint;
      #   a warning is issued (once per process) when +session.reasoning+ is set
      # - +safety_identifier+ — no equivalent user-safety field on the Converse endpoint
      # - +store+ — server-side response storage is not supported
      # - +stream+ — SSE streaming is handled outside the Converse request payload
      # - +stream_options+ — stream event options are not supported
      # - +top_logprobs+ — log probability output is not supported
      # - +truncation+ — server-side context truncation is not supported
      #
      # Partially supported session fields (unsupported keys/values are omitted):
      # - +metadata+ — only scalar values are forwarded to +requestMetadata+; Hash/Array values are omitted
      # - +text+ — only +format.type == "json_schema"+ is supported
      #
      # Tool choice restrictions:
      # - +tool_choice: "none"+ has no Converse representation and is omitted
      #
      # Input content restrictions:
      # - System and developer messages are hoisted out of conversational order
      #   into the top-level +system+ parameter, merged after +instructions+
      # - +Reasoning+ items are silently skipped
      # - +RefusalContent+ is dropped silently (a parsed response refusal can
      #   stay in session history without breaking subsequent request_payload calls)
      # - +OutputText.annotations+ and +OutputText.logprobs+ are dropped silently
      # - +InputImage+ content is only supported in user messages (assistant images are omitted)
      # - +InputImage.detail+ and +InputImage.file_id+ are silently ignored
      # - +InputFile+ content is only supported in user messages (assistant files are omitted)
      # - +InputFile.file_id+ is silently ignored
      # - +InputVideo+ content is only supported in user messages (assistant videos are omitted)
      # - +InputImage+ requires base64 +data+ or an S3 URI (+s3://...+); content with a
      #   public URL is omitted
      # - +InputFile+ requires base64 +file_data+ or an S3 URI; format is detected from the
      #   filename or +file_url+ extension
      # - +InputVideo+ requires an S3 URI (+s3://...+); a non-S3 URL is omitted
      # - Tool (+FunctionCallOutput+) results support text, image, document, and video content;
      #   other content is omitted
      #
      # === Features in Converse not available through Open Responses
      #
      # The following Converse parameters cannot be set through the Open Responses
      # canonical format but are recognized via session +extra+ keys:
      # - +stopSequences+ — custom stop sequences (+stop_sequences+)
      # - Guardrail policies (+guardrail_config+)
      # - Per-model passthrough fields (+additional_model_request_fields+)
      # - Requested provider response fields (+additional_model_response_field_paths+)
      # - +performanceConfig+ latency settings (+performance_config+)
      # - Prompt management variables (+prompt_variables+)
      #
      # Prompt caching markers (+cachePoint+) are emitted via the +cache_point+
      # content extra. Cross-region routing via inference profiles is selected
      # through the model id and needs no request field.
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
          # Reset the once-per-process reasoning warning. Primarily used in tests.
          #
          # @return [void]
          def reset_reasoning_warning!
            @reasoning_warning_issued = false
          end

          private

          def serialize_request(session)
            # document_name_counts is scoped per request (passed through the
            # build chain) so concurrent serializations don't share counter state.
            ctx = {document_name_counts: Hash.new(0)}

            h = {}
            raise UnsupportedFormatError, "Converse format requires session.model" unless session.model

            warn_reasoning_unsupported! if session.reasoning

            h["modelId"] = session.model

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

            output_config = build_output_config(session)
            h["outputConfig"] = output_config unless output_config.empty?

            metadata = build_request_metadata(session)
            h["requestMetadata"] = metadata unless metadata.empty?

            h["serviceTier"] = {"type" => session.service_tier} if session.service_tier

            tool_config = build_tool_config(session)
            h["toolConfig"] = tool_config if tool_config

            # Session extra: recognized keys for Converse API
            apply_session_extra!(h, session.extra) if session.extra

            h
          end

          # The Converse endpoint has no reasoning/extended thinking parameter,
          # so the reasoning config is dropped. Warn once per process instead of
          # dropping it silently.
          def warn_reasoning_unsupported!
            return if @reasoning_warning_issued

            @reasoning_warning_issued = true
            warn "PromptBuilder: session.reasoning is not supported by the Converse format and was omitted from the request payload"
          end

          def apply_session_extra!(h, extra)
            if extra.key?("stop_sequences")
              inference_config = h["inferenceConfig"] ||= {}
              inference_config["stopSequences"] = extra["stop_sequences"]
            end
            h["guardrailConfig"] = extra["guardrail_config"] if extra.key?("guardrail_config")
            h["additionalModelRequestFields"] = extra["additional_model_request_fields"] if extra.key?("additional_model_request_fields")
            h["additionalModelResponseFieldPaths"] = extra["additional_model_response_field_paths"] if extra.key?("additional_model_response_field_paths")
            h["performanceConfig"] = extra["performance_config"] if extra.key?("performance_config")
            h["promptVariables"] = extra["prompt_variables"] if extra.key?("prompt_variables")
          end

          def build_system(session)
            parts = []

            parts << {"text" => session.instructions} if session.instructions

            session.items.each do |item|
              next unless item.is_a?(Items::Message)
              next unless item.role == "system" || item.role == "developer"

              item.content.each do |content|
                serialized = serialize_system_content(content)
                next unless serialized

                parts << serialized
                if content.respond_to?(:extra) && content.extra && content.extra["cache_point"]
                  parts << {"cachePoint" => {"type" => "default"}}
                end
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
                visible_content = item.content.reject { |c| c.is_a?(Content::RefusalContent) }
                next if visible_content.empty?
                content = []
                visible_content.each do |c|
                  serialized = serialize_content(c, role: role, ctx: ctx)
                  next unless serialized

                  content << serialized
                  if c.respond_to?(:extra) && c.extra && c.extra["cache_point"]
                    content << {"cachePoint" => {"type" => "default"}}
                  end
                end
                next if content.empty?
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
              when Items::Reasoning, Items::Compaction, Items::ItemReference
                # Reasoning, Compaction, and ItemReference items are not supported
                # in the request, so ignore them rather than raising an error.
                next
              end
            end

            merge_consecutive_messages(raw_messages)
          end

          def serialize_system_content(content)
            case content
            when Content::InputText
              {"text" => content.text}
            when Content::OutputText
              validate_output_text!(content)
              {"text" => content.text}
            else
              # Only text content is supported in system/developer messages;
              # other content types are silently omitted.
              nil
            end
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
              validate_output_text!(content) if content.is_a?(Content::OutputText)
              {"text" => content.text}
            when Content::InputImage
              # Assistant image content is not supported; omit it.
              return nil if role == "assistant"

              serialize_image(content)
            when Content::InputFile
              # Assistant file content is not supported; omit it.
              return nil if role == "assistant"

              serialize_document(content, ctx)
            when Content::InputVideo
              # Assistant video content is not supported; omit it.
              return nil if role == "assistant"

              serialize_video(content)
            when Content::RefusalContent
              # RefusalContent can land in the session via a parsed response;
              # drop it silently so subsequent request_payload calls don't fail.
              nil
            else
              # Unsupported content types are silently omitted.
              nil
            end
          end

          # OutputText.annotations and logprobs are output-only metadata from
          # a parsed response; silently ignore them on request serialization so
          # a response with citations/logprobs can sit in session history without
          # breaking subsequent request_payload calls.
          def validate_output_text!(content) # rubocop:disable Lint/UnusedMethodArgument
          end

          def serialize_image(content)
            # InputImage.detail and file_id (in extra) are not supported and are
            # silently ignored.
            format = detect_image_format(content)
            parsed = PromptBuilder.parse_data_url(content.url)
            source = if parsed
              {"bytes" => parsed[1]}
            elsif content.url&.start_with?("s3://")
              {"s3Location" => {"uri" => content.url}}
            else
              raise UnsupportedFormatError,
                "Converse format requires a data URL in InputImage.url or an S3 URI"
            end

            {"image" => {"format" => format, "source" => source}}
          end

          def detect_image_format(content)
            media_type = content.extra && content.extra["media_type"]
            if media_type
              fmt = IMAGE_MEDIA_TYPE_FORMATS[media_type]
              return fmt if fmt
            end

            # Try to extract media type from data URL
            parsed = PromptBuilder.parse_data_url(content.url)
            if parsed
              fmt = IMAGE_MEDIA_TYPE_FORMATS[parsed[0]]
              return fmt if fmt
            end

            url = content.url
            if url
              ext = File.extname(url).delete_prefix(".").downcase
              fmt = IMAGE_URL_EXTENSION_FORMATS[ext]
              return fmt if fmt
            end

            raise UnsupportedFormatError,
              "Converse format could not detect image format; set media_type in extra (e.g. \"image/jpeg\")"
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
            # file_id (in extra) is not supported and is silently ignored.
            format = detect_document_format(content)
            parsed = PromptBuilder.parse_data_url(content.url)
            source = if parsed
              {"bytes" => parsed[1]}
            elsif content.url&.start_with?("s3://")
              {"s3Location" => {"uri" => content.url}}
            else
              raise UnsupportedFormatError,
                "Converse format requires InputFile with a data URL or an S3 URI"
            end

            name = document_name(content, ctx)
            {"document" => {"format" => format, "name" => name, "source" => source}}
          end

          def detect_document_format(content)
            media_type = content.extra && content.extra["media_type"]
            if media_type
              fmt = DOCUMENT_MEDIA_TYPE_FORMATS[media_type]
              return fmt if fmt
            end

            # Check the data URL media type
            parsed = PromptBuilder.parse_data_url(content.url)
            if parsed
              fmt = DOCUMENT_MEDIA_TYPE_FORMATS[parsed[0]]
              return fmt if fmt
            end

            [content.filename, content.url].each do |path|
              next unless path

              ext = File.extname(path).delete_prefix(".").downcase
              fmt = DOCUMENT_FILENAME_EXTENSION_FORMATS[ext]
              return fmt if fmt
            end

            raise UnsupportedFormatError,
              "Converse format could not detect document format; set media_type in extra or use a recognized file extension on InputFile.filename or InputFile.url"
          end

          # Bedrock requires document.name to be unique within a request and to
          # match /^[A-Za-z0-9 \-\(\)\[\]]{1,256}$/. Prefer the filename, fall
          # back to the url basename, then a random suffix to avoid
          # collisions when multiple unnamed documents are attached. The counter
          # state lives on the per-request `ctx` Hash so concurrent calls don't
          # share state.
          def document_name(content, ctx)
            source = content.filename || content.url
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
            unless content.url
              raise UnsupportedFormatError,
                "Converse format requires InputVideo.url"
            end

            # Only S3 URIs are supported; other video URLs are silently omitted.
            return nil unless content.url.start_with?("s3://")

            ext = File.extname(content.url).delete_prefix(".").downcase
            format = VIDEO_URL_EXTENSION_FORMATS[ext]

            unless format
              raise UnsupportedFormatError,
                "Converse format could not detect video format from InputVideo.url extension"
            end

            {"video" => {"format" => format, "source" => {"s3Location" => {"uri" => content.url}}}}
          end

          def serialize_tool_result(item, ctx)
            result = {"toolUseId" => item.call_id}

            status = converse_tool_result_status(item.status)
            result["status"] = status if status

            content = if item.output.is_a?(Array)
              item.output.filter_map { |c| serialize_tool_result_content(c, ctx) }
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

          def serialize_tool_result_content(content, ctx)
            case content
            when Content::InputText, Content::OutputText
              validate_output_text!(content) if content.is_a?(Content::OutputText)
              {"text" => content.text}
            when Content::InputImage
              serialize_image(content)
            when Content::InputFile
              serialize_document(content, ctx)
            when Content::InputVideo
              serialize_video(content)
            else
              # Unsupported content types in tool output are silently omitted.
              nil
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

          def build_output_config(session)
            return {} unless session.text

            # Unsupported text.* keys are silently omitted; only format is mapped.
            format = session.text["format"]
            return {} unless format

            # Only json_schema output is supported; other format types are omitted.
            return {} unless format.is_a?(Hash) && format["type"] == "json_schema"

            schema = format.dig("json_schema", "schema") || format["schema"]
            unless schema
              raise UnsupportedFormatError,
                "Converse format requires text.format.schema for json_schema output"
            end

            json_schema = {"schema" => schema.is_a?(String) ? schema : JSON.generate(schema)}
            name = format.dig("json_schema", "name") || format["name"]
            description = format.dig("json_schema", "description") || format["description"]
            json_schema["name"] = name if name
            json_schema["description"] = description if description

            {
              "textFormat" => {
                "type" => "json_schema",
                "structure" => {"jsonSchema" => json_schema}
              }
            }
          end

          def build_request_metadata(session)
            return {} unless session.metadata

            # Only scalar metadata values are supported; Hash/Array values are
            # silently omitted.
            session.metadata.each_with_object({}) do |(key, value), metadata|
              next if value.is_a?(Hash) || value.is_a?(Array)

              metadata[key.to_s] = value.to_s
            end
          end

          def build_tool_config(session)
            tools = build_tools(session)
            return nil if tools.empty? && session.tool_choice.nil?

            config = {}
            config["tools"] = tools unless tools.empty?
            if session.tool_choice
              tool_choice = serialize_tool_choice(session.tool_choice, tools.empty?)
              config["toolChoice"] = tool_choice if tool_choice
            end

            return nil if config.empty?

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

          # Unsupported tool_choice values (including tool_choice without tools
          # and "none", which Converse has no representation for) are silently
          # omitted by returning nil.
          def serialize_tool_choice(choice, tools_empty)
            return nil if tools_empty

            case choice
            when "auto"
              {"auto" => {}}
            when "required"
              {"any" => {}}
            when Hash
              if choice["type"] == "function"
                name = choice["name"] || choice.dig("function", "name")
                unless name
                  raise UnsupportedFormatError,
                    "Converse format requires tool_choice.name for function tool choices"
                end

                {"tool" => {"name" => name}}
              end
            end
          end
        end
      end
    end
  end
end
