# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class Messages < Base
      # Request serializer for the Anthropic Messages API format.
      #
      # === Unsupported Open Responses features
      #
      # These session fields are not supported and raise +UnsupportedFormatError+:
      # - +frequency_penalty+ — not supported by the Messages API
      # - +include+ — response-field inclusion is an Open Responses-only concept
      # - +max_tool_calls+ — per-request tool-call caps are not supported
      # - +presence_penalty+ — not supported by the Messages API
      # - +prompt_cache_key+ / +prompt_cache_retention+ — explicit prompt cache keys are not supported
      # - +store+ — server-side response storage is not supported
      # - +stream_options+ — stream event options are not supported
      # - +top_logprobs+ — log probability output is not supported
      # - +truncation+ — server-side context truncation is not supported
      # - +background+ — background/async mode is not supported on the Messages endpoint
      #
      # Unsupported (raises +UnsupportedFormatError+):
      # - +text.verbosity+ — Anthropic Messages has no equivalent verbosity control
      #
      # Partially supported session fields (unsupported keys raise +UnsupportedFormatError+):
      # - +metadata+ — only the +user_id+ key is forwarded; +safety_identifier+ is
      #   also mapped into +metadata.user_id+ automatically
      # - +service_tier+ — only +auto+ and +standard_only+ are accepted
      # - +text+ — +format.type=json_schema+ is mapped to +output_config.format+
      # - +reasoning+ — +budget_tokens+, +display+, +effort+, and +type+ are forwarded;
      #   +temperature+ must be unset and +top_p+ must be >= 0.95 when reasoning is enabled
      #
      # Input content restrictions:
      # - +InputVideo+ content is not supported
      # - +RefusalContent+ is dropped silently (a parsed refusal can stay in
      #   session history without breaking subsequent request_payload calls)
      # - +InputImage+ content is only supported in user messages (not assistant)
      # - +InputImage.detail+ is not part of the Anthropic schema and is dropped
      # - +InputImage.file_id+ is mapped to a +file+ source (Anthropic Files API beta)
      # - +InputFile+ content is only supported in user messages (not assistant)
      # - +InputFile+ is sent as a +document+ block; +media_type+ is forwarded when
      #   provided, otherwise +application/pdf+ is used for base64 sources
      # - +InputFile.file_id+ is mapped to a +file+ source (Anthropic Files API beta)
      # - Thinking blocks without a +signature+ are dropped silently (cross-provider
      #   reasoning history doesn't round-trip into Anthropic)
      # - +Reasoning+ items with +summary+ blocks are not supported
      # - Forced tool choice (+any+/+tool+ type) is incompatible with thinking enabled
      # - +Compaction+ and +ItemReference+ items are not supported
      # - +FunctionCallOutput.status+ values +incomplete+, +failed+, and +error+
      #   are mapped to +tool_result.is_error: true+
      #
      # === Features in the Messages API not available through Open Responses
      #
      # The following Messages API parameters cannot be set through the Open Responses
      # canonical format:
      # - +top_k+ — top-K sampling parameter
      # - +stop_sequences+ — custom stop sequences
      # - +cache_control+ — top-level prompt-cache breakpoint selection
      # - +inference_geo+ — geographic inference routing
      # - +mcp_servers+ — MCP connector beta parameter
      # - +container+ — code execution container reuse parameter
      # - +cache_control+ markers on system blocks, message content blocks,
      #   tool definitions, or document blocks (prompt caching)
      # - Citations on documents and tool_result content blocks
      # - +search_result+ content blocks
      # - Web search, code execution, computer use, bash tool, text editor, and
      #   memory built-in tools
      # - Redacted thinking round-trip (+redacted_thinking+ blocks are supported
      #   when they appear in conversation history but cannot be requested via OR)
      # - Cryptographic thinking signatures (passed through in history but not
      #   configurable as a generation parameter)
      # - +anthropic-beta+ headers and API versioning (this gem produces no HTTP
      #   request — set headers in your HTTP client)
      class Request < Base
        DEFAULT_MAX_TOKENS = 4096
        SUPPORTED_METADATA_KEYS = ["user_id"].freeze
        EFFORT_LEVELS = ["low", "medium", "high", "xhigh", "max"].freeze
        SUPPORTED_REASONING_KEYS = ["budget_tokens", "display", "effort", "type"].freeze
        SUPPORTED_TEXT_KEYS = ["format"].freeze
        SUPPORTED_THINKING_TYPES = ["adaptive", "disabled", "enabled"].freeze
        SUPPORTED_TOOL_CHOICE_TYPES = ["any", "auto", "none", "tool"].freeze

        class << self
          private

          def serialize_request(session)
            validate_supported_session_fields!(session)

            h = {}
            raise UnsupportedFormatError, "Messages format requires session.model" unless session.model

            h["model"] = session.model
            h["max_tokens"] = session.max_output_tokens || DEFAULT_MAX_TOKENS
            h["temperature"] = session.temperature if session.temperature
            h["top_p"] = session.top_p if session.top_p
            effective_metadata = build_effective_metadata(session)
            h["metadata"] = effective_metadata if effective_metadata
            h["service_tier"] = serialize_service_tier(session.service_tier) if session.service_tier
            h["stream"] = session.stream unless session.stream.nil?

            # Session extra: recognized keys for Messages API
            apply_session_extra!(h, session.extra) if session.extra

            output_config = build_output_config(session)
            h["output_config"] = output_config unless output_config.empty?

            thinking = serialize_thinking(session.reasoning)
            validate_thinking_compatibility!(session, thinking) if thinking_active?(thinking)
            h["thinking"] = thinking if thinking

            system_parts = build_system(session)
            h["system"] = system_parts unless system_parts.empty?

            messages = build_messages(session)
            if messages.empty?
              raise UnsupportedFormatError,
                "Messages format requires at least one user/assistant message"
            end
            unless messages.first["role"] == "user"
              raise UnsupportedFormatError,
                "Messages format requires the first message to have role \"user\""
            end
            h["messages"] = messages

            tools = build_tools(session)
            h["tools"] = tools unless tools.empty?

            tool_choice = serialize_tool_choice(
              session.tool_choice,
              tools: tools,
              parallel_tool_calls: session.parallel_tool_calls,
              thinking_enabled: thinking_active?(thinking)
            )
            h["tool_choice"] = tool_choice if tool_choice

            h
          end

          def apply_session_extra!(h, extra)
            h["top_k"] = extra["top_k"] if extra.key?("top_k")
            h["stop_sequences"] = extra["stop_sequences"] if extra.key?("stop_sequences")
            h["cache_control"] = extra["cache_control"] if extra.key?("cache_control")
          end

          def validate_supported_session_fields!(session)
            unsupported_fields = []
            unsupported_fields << "include" if session.include
            unsupported_fields << "presence_penalty" if session.presence_penalty
            unsupported_fields << "frequency_penalty" if session.frequency_penalty
            unsupported_fields << "stream_options" if session.stream_options
            unsupported_fields << "background" unless session.background.nil?
            unsupported_fields << "max_tool_calls" if session.max_tool_calls
            unsupported_fields << "prompt_cache_key" if session.prompt_cache_key
            unsupported_fields << "prompt_cache_retention" if session.prompt_cache_retention
            unsupported_fields << "truncation" if session.truncation
            unsupported_fields << "store" unless session.store.nil?
            unsupported_fields << "top_logprobs" if session.top_logprobs
            return if unsupported_fields.empty?

            raise UnsupportedFormatError,
              "Messages format does not support session fields: #{unsupported_fields.join(", ")}"
          end

          def build_effective_metadata(session)
            metadata = session.metadata&.dup || {}

            if session.safety_identifier
              existing_user_id = metadata["user_id"]
              if existing_user_id && existing_user_id != session.safety_identifier
                raise UnsupportedFormatError,
                  "Messages format has conflicting safety_identifier and metadata.user_id values"
              end
              metadata["user_id"] = session.safety_identifier
            end

            return nil if metadata.empty?

            serialize_metadata(metadata)
          end

          def serialize_metadata(metadata)
            unsupported_keys = metadata.keys - SUPPORTED_METADATA_KEYS
            unless unsupported_keys.empty?
              raise UnsupportedFormatError,
                "Messages format does not support metadata.#{unsupported_keys.first}"
            end

            metadata
          end

          def serialize_service_tier(service_tier)
            return service_tier if ["auto", "standard_only"].include?(service_tier)

            raise UnsupportedFormatError,
              "Messages format only supports service_tier values auto and standard_only"
          end

          def serialize_thinking(reasoning)
            return nil unless reasoning

            unsupported_keys = reasoning.keys - SUPPORTED_REASONING_KEYS
            unless unsupported_keys.empty?
              raise UnsupportedFormatError,
                "Messages format does not support reasoning.#{unsupported_keys.first}"
            end

            thinking = {}
            thinking["budget_tokens"] = reasoning["budget_tokens"] if reasoning.key?("budget_tokens")
            thinking["display"] = reasoning["display"] if reasoning["display"]
            return nil if thinking.empty? && !reasoning["type"]

            thinking["type"] = reasoning["type"] || "enabled"

            unless SUPPORTED_THINKING_TYPES.include?(thinking["type"])
              raise UnsupportedFormatError,
                "Messages format does not support reasoning.type #{thinking["type"].inspect}"
            end

            if thinking["type"] == "enabled" && !thinking.key?("budget_tokens")
              raise UnsupportedFormatError,
                "Messages format requires reasoning.budget_tokens when thinking is enabled"
            end

            if thinking["type"] != "enabled" && thinking.key?("budget_tokens")
              raise UnsupportedFormatError,
                "Messages format only supports reasoning.budget_tokens when reasoning.type is enabled"
            end

            if thinking["type"] == "disabled" && thinking.key?("display")
              raise UnsupportedFormatError,
                "Messages format does not support reasoning.display when reasoning.type is disabled"
            end

            thinking
          end

          def thinking_active?(thinking)
            thinking && thinking["type"] != "disabled"
          end

          def build_output_config(session)
            output_config = {}

            if session.reasoning && session.reasoning["effort"]
              effort = session.reasoning["effort"]
              unless EFFORT_LEVELS.include?(effort)
                raise UnsupportedFormatError,
                  "Messages format does not support reasoning.effort #{effort.inspect}"
              end

              output_config["effort"] = effort
            end

            if session.text
              unsupported_keys = session.text.keys - SUPPORTED_TEXT_KEYS
              unless unsupported_keys.empty?
                raise UnsupportedFormatError,
                  "Messages format does not support text.#{unsupported_keys.first}"
              end

              output_format = serialize_output_format(session.text["format"])
              output_config["format"] = output_format if output_format
            end

            output_config
          end

          def serialize_output_format(format)
            return nil unless format

            unless format.is_a?(Hash) && format["type"] == "json_schema"
              raise UnsupportedFormatError,
                "Messages format only supports text.format type \"json_schema\""
            end

            unsupported_keys = format.keys - ["json_schema", "schema", "type", "name", "strict", "description"]
            unless unsupported_keys.empty?
              raise UnsupportedFormatError,
                "Messages format does not support text.format.#{unsupported_keys.first}"
            end

            if format["json_schema"].is_a?(Hash)
              unsupported_json_schema_keys = format["json_schema"].keys - ["schema", "name", "strict", "description"]
              unless unsupported_json_schema_keys.empty?
                raise UnsupportedFormatError,
                  "Messages format does not support text.format.json_schema.#{unsupported_json_schema_keys.first}"
              end
            end

            schema = format.dig("json_schema", "schema") || format["schema"]
            unless schema
              raise UnsupportedFormatError,
                "Messages format requires text.format.schema for json_schema output"
            end

            {"type" => "json_schema", "schema" => schema}
          end

          def validate_thinking_compatibility!(session, thinking)
            return unless thinking

            if session.temperature
              raise UnsupportedFormatError,
                "Messages format does not support temperature when thinking is enabled"
            end

            return unless session.top_p && session.top_p < 0.95

            raise UnsupportedFormatError,
              "Messages format requires top_p >= 0.95 when thinking is enabled"
          end

          def build_system(session)
            parts = []

            if session.instructions
              parts << {"type" => "text", "text" => session.instructions}
            end

            session.items.each do |item|
              next unless item.is_a?(Items::Message)
              next unless item.role == "system" || item.role == "developer"

              item.content.each do |content|
                if content.is_a?(Content::InputText)
                  part = {"type" => "text", "text" => content.text}
                  if content.extra && content.extra["cache_control"]
                    part["cache_control"] = content.extra["cache_control"]
                  end
                  parts << part
                end
              end
            end

            parts
          end

          def build_messages(session)
            raw_messages = []

            session.items.each do |item|
              case item
              when Items::Message
                next if item.role == "system" || item.role == "developer"

                role = (item.role == "assistant") ? "assistant" : "user"
                # RefusalContent is dropped silently: it can land in the session
                # via a parsed Chat Completions response, but cannot be sent back
                # to any provider in a request payload.
                visible_content = item.content.reject { |c| c.is_a?(Content::RefusalContent) }
                next if visible_content.empty?
                content = visible_content.map { |message_content| serialize_content(message_content, role: role) }
                raw_messages << {"role" => role, "content" => content}
              when Items::FunctionCall
                raw_messages << {
                  "role" => "assistant",
                  "content" => [{
                    "type" => "tool_use",
                    "id" => item.call_id,
                    "name" => item.name,
                    "input" => item.parsed_arguments
                  }]
                }
              when Items::FunctionCallOutput
                raw_messages << {
                  "role" => "user",
                  "content" => [serialize_tool_result(item)]
                }
              when Items::Reasoning
                unless item.summary.empty?
                  raise UnsupportedFormatError,
                    "Messages format cannot serialize Reasoning summary blocks; " \
                    "Anthropic requires signed thinking blocks (use a Reasoning item produced by the Messages API)"
                end

                content_blocks = item.content.map { |block| serialize_reasoning_block(block) }.compact
                unless content_blocks.empty?
                  raw_messages << {"role" => "assistant", "content" => content_blocks}
                end
              when Items::Compaction
                raise UnsupportedFormatError, "Messages format does not support Compaction items"
              when Items::ItemReference
                raise UnsupportedFormatError, "Messages format does not support ItemReference items"
              end
            end

            merge_consecutive_messages(raw_messages)
          end

          def serialize_content(content, role:)
            block = serialize_content_block(content, role: role)
            return nil unless block

            # Apply cache_control from content extra if present
            if content.respond_to?(:extra) && content.extra && content.extra["cache_control"]
              block["cache_control"] = content.extra["cache_control"]
            end

            block
          end

          def serialize_content_block(content, role:)
            case content
            when Content::InputText
              {"type" => "text", "text" => content.text}
            when Content::OutputText
              text = {"type" => "text", "text" => content.text}
              text["citations"] = content.annotations unless content.annotations.empty?
              text
            when Content::InputImage
              if role == "assistant"
                raise UnsupportedFormatError,
                  "Messages format does not support assistant #{content.class.name.split("::").last} content"
              end

              file_id = content.extra && content.extra["file_id"]

              if content.image_url
                parsed = PromptBuilder.parse_data_url(content.image_url)
                if parsed
                  {
                    "type" => "image",
                    "source" => {
                      "type" => "base64",
                      "media_type" => parsed[0],
                      "data" => parsed[1]
                    }
                  }
                else
                  {
                    "type" => "image",
                    "source" => {"type" => "url", "url" => content.image_url}
                  }
                end
              elsif file_id
                {
                  "type" => "image",
                  "source" => {"type" => "file", "file_id" => file_id}
                }
              else
                raise UnsupportedFormatError,
                  "Messages format requires InputImage.image_url or file_id in extra"
              end
            when Content::InputFile
              if role == "assistant"
                raise UnsupportedFormatError,
                  "Messages format does not support assistant #{content.class.name.split("::").last} content"
              end

              file_id = content.extra && content.extra["file_id"]
              media_type = content.extra && content.extra["media_type"]

              if content.file_url
                document = {
                  "type" => "document",
                  "source" => {"type" => "url", "url" => content.file_url}
                }
              elsif content.file_data
                document = {
                  "type" => "document",
                  "source" => {
                    "type" => "base64",
                    "media_type" => media_type || "application/pdf",
                    "data" => content.file_data
                  }
                }
              elsif file_id
                document = {
                  "type" => "document",
                  "source" => {"type" => "file", "file_id" => file_id}
                }
              else
                raise UnsupportedFormatError,
                  "Messages format requires InputFile.file_url, InputFile.file_data, or file_id in extra"
              end

              document["title"] = content.filename if content.filename
              # Apply citations opt-in from extra
              if content.extra && content.extra["citations"]
                document["citations"] = content.extra["citations"]
              end
              document
            when Content::InputVideo
              raise UnsupportedFormatError, "Messages format does not support InputVideo content"
            when Content::RefusalContent
              # Filtered out before reaching here; treat as a defensive no-op.
              nil
            else
              raise UnsupportedFormatError, "Unsupported content type: #{content.class}"
            end
          end

          # FunctionCallOutput.status values that map to tool_result.is_error.
          # "incomplete" and "failed" cover the OR canonical statuses; "error"
          # is accepted as a convenience alias.
          ERROR_TOOL_OUTPUT_STATUSES = %w[incomplete failed error].freeze
          private_constant :ERROR_TOOL_OUTPUT_STATUSES

          def serialize_tool_result(item)
            result = {
              "type" => "tool_result",
              "tool_use_id" => item.call_id
            }
            content = if item.output.is_a?(Array)
              item.output.map { |c| serialize_tool_result_content(c) }
            elsif !item.output.nil?
              # String outputs are passed through directly per Anthropic's schema.
              item.output
            end

            # Anthropic requires tool_result.content; collapse missing/empty
            # array outputs to a single empty text block.
            content = [{"type" => "text", "text" => ""}] if content.nil? || (content.is_a?(Array) && content.empty?)
            result["content"] = content
            result["is_error"] = true if ERROR_TOOL_OUTPUT_STATUSES.include?(item.status)
            result
          end

          # Anthropic's tool_result.content only accepts text and image blocks.
          # Document blocks are rejected by the API.
          def serialize_tool_result_content(content)
            case content
            when Content::InputText, Content::OutputText
              {"type" => "text", "text" => content.text}
            when Content::InputImage
              serialize_content(content, role: "user")
            else
              raise UnsupportedFormatError,
                "#{content.class.name.split("::").last} is not supported in tool_result.content " \
                "in Messages format; Anthropic only accepts text and image blocks here"
            end
          end

          def serialize_reasoning_block(block)
            case block["type"]
            when "thinking"
              # Anthropic only accepts thinking blocks it has signed. Unsigned
              # thinking from cross-provider history (e.g. parsed from a Gemini
              # response) is dropped rather than rejected.
              return nil unless block["signature"]

              {
                "type" => "thinking",
                "thinking" => block.fetch("thinking", ""),
                "signature" => block["signature"]
              }
            when "redacted_thinking"
              unless block["data"]
                raise UnsupportedFormatError,
                  "Messages format requires reasoning.data for redacted_thinking blocks"
              end

              {
                "type" => "redacted_thinking",
                "data" => block["data"]
              }
            else
              raise UnsupportedFormatError,
                "Messages format does not support reasoning block type #{block["type"].inspect}"
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

          def build_tools(session)
            session.tool_definitions.map do |definition|
              tool = {"name" => definition.name}
              tool["description"] = definition.description if definition.description
              tool["input_schema"] = definition.parameters || {"type" => "object", "properties" => {}}
              tool["strict"] = true if definition.strict
              tool["cache_control"] = definition.extra["cache_control"] if definition.extra["cache_control"]
              tool
            end
          end

          def serialize_tool_choice(choice, tools:, parallel_tool_calls:, thinking_enabled:)
            if choice.nil?
              return nil if parallel_tool_calls.nil?

              if tools.empty?
                raise UnsupportedFormatError,
                  "Messages format does not support parallel_tool_calls without tools"
              end

              return nil if parallel_tool_calls

              return {
                "type" => "auto",
                "disable_parallel_tool_use" => true
              }
            end

            normalized_choice = normalize_tool_choice(choice)

            if tools.empty? && normalized_choice["type"] != "none"
              raise UnsupportedFormatError,
                "Messages format does not support tool_choice without tools"
            end

            if thinking_enabled && ["any", "tool"].include?(normalized_choice["type"])
              raise UnsupportedFormatError,
                "Messages format does not support forced tool_choice when thinking is enabled"
            end

            apply_parallel_tool_calls(normalized_choice, parallel_tool_calls)
          end

          def normalize_tool_choice(choice)
            case choice
            when "auto"
              {"type" => "auto"}
            when "required"
              {"type" => "any"}
            when "none"
              {"type" => "none"}
            when Hash
              if choice["type"] == "function"
                name = choice["name"] || choice.dig("function", "name")
                unless name
                  raise UnsupportedFormatError,
                    "Messages format requires tool_choice.name for function tool choices"
                end

                {"type" => "tool", "name" => name}
              else
                validate_tool_choice_hash!(choice)
                choice.dup
              end
            else
              raise UnsupportedFormatError,
                "Messages format does not support tool_choice #{choice.inspect}"
            end
          end

          def validate_tool_choice_hash!(choice)
            type = choice["type"]
            unless SUPPORTED_TOOL_CHOICE_TYPES.include?(type)
              raise UnsupportedFormatError,
                "Messages format does not support tool_choice.type #{type.inspect}"
            end

            allowed_keys = case type
            when "auto", "any"
              ["disable_parallel_tool_use", "type"]
            when "tool"
              ["disable_parallel_tool_use", "name", "type"]
            when "none"
              ["type"]
            end

            unsupported_keys = choice.keys - allowed_keys
            unless unsupported_keys.empty?
              raise UnsupportedFormatError,
                "Messages format does not support tool_choice.#{unsupported_keys.first}"
            end

            if type == "tool" && !choice["name"]
              raise UnsupportedFormatError,
                "Messages format requires tool_choice.name when type is tool"
            end
          end

          def apply_parallel_tool_calls(choice, parallel_tool_calls)
            return choice if parallel_tool_calls.nil?

            if choice["type"] == "none"
              raise UnsupportedFormatError,
                "Messages format does not support parallel_tool_calls with tool_choice.none"
            end

            if parallel_tool_calls
              if choice["disable_parallel_tool_use"] == true
                raise UnsupportedFormatError,
                  "Messages format received conflicting parallel_tool_calls and tool_choice.disable_parallel_tool_use"
              end

              choice.delete("disable_parallel_tool_use")
              return choice
            end

            if choice["disable_parallel_tool_use"] == false
              raise UnsupportedFormatError,
                "Messages format received conflicting parallel_tool_calls and tool_choice.disable_parallel_tool_use"
            end

            choice["disable_parallel_tool_use"] = true
            choice
          end
        end
      end
    end
  end
end
