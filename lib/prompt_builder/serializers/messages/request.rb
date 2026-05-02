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
      # - +prompt_cache_key+ — explicit prompt cache keys are not supported
      # - +store+ — server-side response storage is not supported
      # - +stream_options+ — stream event options are not supported
      # - +top_logprobs+ — log probability output is not supported
      # - +truncation+ — server-side context truncation is not supported
      # - +background+ — background/async mode is not supported on the Messages endpoint
      #
      # Partially supported session fields (unsupported keys raise +UnsupportedFormatError+):
      # - +metadata+ — only the +user_id+ key is forwarded; +safety_identifier+ is
      #   also mapped into +metadata.user_id+ automatically
      # - +service_tier+ — only +auto+ and +standard_only+ are accepted
      # - +text+ — only the +format+ key is forwarded
      # - +reasoning+ — +budget_tokens+, +display+, +effort+, and +type+ are forwarded;
      #   +temperature+ must be unset and +top_p+ must be >= 0.95 when reasoning is enabled
      #
      # Input content restrictions:
      # - +InputVideo+ content is not supported
      # - +RefusalContent+ is not supported in request messages
      # - +InputImage+ content is only supported in user messages (not assistant)
      # - +InputFile+ content is only supported in user messages (not assistant)
      # - Thinking blocks (+Reasoning+ items) require a +signature+ field
      # - Forced tool choice (+any+/+tool+ type) is incompatible with thinking enabled
      #
      # === Features in the Messages API not available through Open Responses
      #
      # The following Messages API parameters cannot be set through the Open Responses
      # canonical format:
      # - +top_k+ — top-K sampling parameter
      # - +stop_sequences+ — custom stop sequences
      # - Web search, code execution, computer use, bash tool, text editor, and
      #   memory built-in tools
      # - Redacted thinking round-trip (+redacted_thinking+ blocks are supported
      #   when they appear in conversation history but cannot be requested via OR)
      # - Cryptographic thinking signatures (passed through in history but not
      #   configurable as a generation parameter)
      class Request < Base
        DEFAULT_MAX_TOKENS = 4096
        SUPPORTED_METADATA_KEYS = ["user_id"].freeze
        SUPPORTED_TEXT_KEYS = ["format"].freeze
        SUPPORTED_REASONING_KEYS = ["budget_tokens", "display", "effort", "type"].freeze
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

            thinking = serialize_thinking(session.reasoning)
            validate_thinking_compatibility!(session, thinking) if thinking
            h["thinking"] = thinking if thinking

            output_config = serialize_output_config(session.text, session.reasoning)
            h["output_config"] = output_config unless output_config.empty?

            system_parts = build_system(session)
            h["system"] = system_parts unless system_parts.empty?

            h["messages"] = build_messages(session)

            tools = build_tools(session)
            h["tools"] = tools unless tools.empty?

            tool_choice = serialize_tool_choice(
              session.tool_choice,
              tools: tools,
              parallel_tool_calls: session.parallel_tool_calls,
              thinking_enabled: !thinking.nil?
            )
            h["tool_choice"] = tool_choice if tool_choice

            h
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
            thinking["type"] = reasoning["type"] if reasoning["type"]
            thinking["budget_tokens"] = reasoning["budget_tokens"] if reasoning.key?("budget_tokens")
            thinking["display"] = reasoning["display"] if reasoning["display"]
            thinking.empty? ? nil : thinking
          end

          def serialize_output_config(text, reasoning)
            output_config = {}

            if text
              unsupported_keys = text.keys - SUPPORTED_TEXT_KEYS
              unless unsupported_keys.empty?
                raise UnsupportedFormatError,
                  "Messages format does not support text.#{unsupported_keys.first}"
              end

              output_config["format"] = text["format"] if text["format"]
            end

            if reasoning && reasoning["effort"]
              output_config["effort"] = reasoning["effort"]
            end

            output_config
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
                parts << {"type" => "text", "text" => content.text} if content.is_a?(Content::InputText)
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
                content = item.content.map { |message_content| serialize_content(message_content, role: role) }
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
                content_blocks = item.content.map { |block| serialize_reasoning_block(block) }
                unless content_blocks.empty?
                  raw_messages << {"role" => "assistant", "content" => content_blocks}
                end
              end
            end

            merge_consecutive_messages(raw_messages)
          end

          def serialize_content(content, role:)
            case content
            when Content::InputText
              {"type" => "text", "text" => content.text}
            when Content::OutputText
              {"type" => "text", "text" => content.text}
            when Content::InputImage
              if role == "assistant"
                raise UnsupportedFormatError,
                  "Messages format does not support assistant #{content.class.name.split("::").last} content"
              end

              if content.image_url
                image = {
                  "type" => "image",
                  "source" => {"type" => "url", "url" => content.image_url}
                }
                image["detail"] = content.detail if content.detail
                image
              elsif content.data
                unless content.media_type
                  raise UnsupportedFormatError,
                    "Messages format requires InputImage.media_type for base64 image content"
                end

                image = {
                  "type" => "image",
                  "source" => {
                    "type" => "base64",
                    "media_type" => content.media_type,
                    "data" => content.data
                  }
                }
                image["detail"] = content.detail if content.detail
                image
              else
                raise UnsupportedFormatError,
                  "Messages format requires InputImage.image_url or InputImage.data"
              end
            when Content::InputFile
              if role == "assistant"
                raise UnsupportedFormatError,
                  "Messages format does not support assistant #{content.class.name.split("::").last} content"
              end

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
                    "media_type" => "application/pdf",
                    "data" => content.file_data
                  }
                }
              else
                raise UnsupportedFormatError,
                  "Messages format requires InputFile.file_url or InputFile.file_data"
              end

              document["title"] = content.filename if content.filename
              document
            when Content::InputVideo
              raise UnsupportedFormatError, "Messages format does not support InputVideo content"
            when Content::RefusalContent
              raise UnsupportedFormatError, "Messages format does not support RefusalContent"
            else
              raise UnsupportedFormatError, "Unsupported content type: #{content.class}"
            end
          end

          def serialize_tool_result(item)
            result = {
              "type" => "tool_result",
              "tool_use_id" => item.call_id
            }
            if item.output.is_a?(Array)
              content = item.output.map { |c| serialize_content(c, role: "user") }
              result["content"] = content unless content.empty?
            elsif !item.output.nil? && !item.output.empty?
              result["content"] = item.output
            end
            result
          end

          def serialize_reasoning_block(block)
            case block["type"]
            when "thinking"
              unless block["signature"]
                raise UnsupportedFormatError,
                  "Messages format requires reasoning.signature for thinking blocks"
              end

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
              tool["strict"] = definition.strict if definition.strict
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
                unless choice["name"]
                  raise UnsupportedFormatError,
                    "Messages format requires tool_choice.name for function tool choices"
                end

                {"type" => "tool", "name" => choice["name"]}
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
