# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class ChatCompletion < Base
      # Request serializer for the OpenAI Chat Completions API format.
      #
      # Required session fields (an UnsupportedFormatError is raised when missing):
      # - +model+
      # - at least one message (+instructions+ or a conversation item that
      #   serializes to a message)
      #
      # === Unsupported Open Responses features
      #
      # These session fields are not supported and are silently omitted from the
      # serialized output:
      # - +background+ — Chat Completions has no background/async mode
      # - +include+ — response-field inclusion is an Open Responses-only concept
      # - +max_tool_calls+ — per-request tool-call caps are not supported
      # - +truncation+ — server-side context truncation is not supported
      #
      # Partially supported session fields (unsupported keys are omitted):
      # - +text+ — only +format+ (mapped to +response_format+) and +verbosity+
      #   (mapped to top-level +verbosity+) are supported
      # - +reasoning+ — only the +effort+ key is mapped to +reasoning_effort+
      # - +stream_options+ — only +include_usage+ and +include_obfuscation+ are
      #   supported, and only when +stream+ is set (otherwise it is omitted)
      #
      # Input content restrictions:
      # - +InputVideo+ content is not supported in any message (omitted)
      # - +Reasoning+ items are not supported (skipped)
      # - +RefusalContent+ is dropped silently (a parsed Chat Completions
      #   refusal can stay in session history without breaking subsequent
      #   request_payload calls)
      # - +InputImage+ content is only supported in user messages (assistant/developer/system images are omitted)
      # - +InputImage+ with +file_id+ in +extra+ is not supported (the +image_file+
      #   content type is Assistants API only); a +file_id+-only image is omitted
      # - +InputFile+ is mapped to a +file+ content block (Files API id via +extra+,
      #   base64 +file_data+, or both with +filename+); a +file_url+-only +InputFile+
      #   is omitted because Chat Completions has no remote-URL form for files
      # - Only text content is supported in tool (+FunctionCallOutput+) results;
      #   other content is omitted
      # - +OutputText.annotations+ are dropped silently on request serialization
      #   so a parsed response with citations can sit in session history without
      #   breaking subsequent +request_payload+ calls
      #
      # === Features in Chat Completions not available through Open Responses
      #
      # The following Chat Completions parameters cannot be set through the Open
      # Responses canonical format:
      # - +seed+ — for reproducible outputs
      # - +logit_bias+ — per-token probability adjustments
      # - +n+ — requesting multiple response candidates
      # - +stop+ — custom stop sequences
      # - +prediction+ — speculative decoding hints
      # - Audio input and audio output (model-dependent)
      # - +web_search_options+ — built-in web search tool
      # - +modalities+ — output modality selection (text/audio)
      # - +tool_choice+ +allowed_tools+ shape and custom (non-function) tool types
      class Request < Base
        SUPPORTED_MESSAGE_ROLES = %w[assistant developer system user].freeze
        SUPPORTED_STREAM_OPTION_KEYS = %w[include_obfuscation include_usage].freeze
        SUPPORTED_TOOL_CHOICE_VALUES = %w[auto none required].freeze

        class << self
          private

          def serialize_request(session)
            h = {}
            raise UnsupportedFormatError, "Chat Completions format requires session.model" unless session.model

            h["model"] = session.model
            messages = build_messages(session)
            if messages.empty?
              raise UnsupportedFormatError, "Chat Completions format requires at least one message"
            end
            h["messages"] = messages
            h["temperature"] = session.temperature if session.temperature
            h["top_p"] = session.top_p if session.top_p
            h["presence_penalty"] = session.presence_penalty if session.presence_penalty
            h["frequency_penalty"] = session.frequency_penalty if session.frequency_penalty
            h["max_completion_tokens"] = session.max_output_tokens if session.max_output_tokens
            h["parallel_tool_calls"] = session.parallel_tool_calls unless session.parallel_tool_calls.nil?
            if session.top_logprobs
              h["logprobs"] = true
              h["top_logprobs"] = session.top_logprobs
            end
            h["store"] = session.store unless session.store.nil?
            h["metadata"] = session.metadata if session.metadata
            h["service_tier"] = session.service_tier if session.service_tier
            h["safety_identifier"] = session.safety_identifier if session.safety_identifier
            h["prompt_cache_key"] = session.prompt_cache_key if session.prompt_cache_key
            h["prompt_cache_retention"] = session.prompt_cache_retention if session.prompt_cache_retention
            h["stream"] = session.stream unless session.stream.nil?
            # stream_options is only valid alongside stream; otherwise it is omitted.
            # Unsupported stream_options keys are dropped.
            if session.stream_options && session.stream
              stream_options = normalize_hash(session.stream_options).slice(*SUPPORTED_STREAM_OPTION_KEYS)
              h["stream_options"] = stream_options unless stream_options.empty?
            end

            if session.text
              text = normalize_hash(session.text)
              h["response_format"] = extract_response_format(text["format"]) if text["format"]
              h["verbosity"] = text["verbosity"] if text["verbosity"]
            end

            if session.reasoning
              effort = normalize_hash(session.reasoning)["effort"]
              h["reasoning_effort"] = effort if effort
            end

            tools = build_tools(session)
            h["tools"] = tools unless tools.empty?

            if session.tool_choice
              tool_choice = serialize_tool_choice(session.tool_choice, tools.empty?)
              h["tool_choice"] = tool_choice if tool_choice
            end

            # Session extra: recognized keys for Chat Completions API
            apply_session_extra!(h, session.extra) if session.extra

            h
          end

          def apply_session_extra!(h, extra)
            h["stop"] = extra["stop"] if extra.key?("stop")
            h["seed"] = extra["seed"] if extra.key?("seed")
            h["logit_bias"] = extra["logit_bias"] if extra.key?("logit_bias")
            h["n"] = extra["n"] if extra.key?("n")
            h["prediction"] = extra["prediction"] if extra.key?("prediction")
            h["web_search_options"] = extra["web_search_options"] if extra.key?("web_search_options")
            h["modalities"] = extra["modalities"] if extra.key?("modalities")
            h["audio"] = extra["audio"] if extra.key?("audio")
          end

          def build_messages(session)
            messages = []

            if session.instructions
              messages << {"role" => "system", "content" => session.instructions}
            end

            pending_tool_calls = []
            last_assistant_msg = nil

            session.items.each do |item|
              case item
              when Items::Message
                flush_tool_calls!(messages, pending_tool_calls, last_assistant_msg)
                msg = serialize_message(item)
                next unless msg
                messages << msg
                last_assistant_msg = (item.role == "assistant") ? msg : nil
              when Items::FunctionCall
                pending_tool_calls << serialize_function_call(item)
              when Items::FunctionCallOutput
                flush_tool_calls!(messages, pending_tool_calls, last_assistant_msg)
                last_assistant_msg = nil
                messages << {
                  "role" => "tool",
                  "tool_call_id" => item.call_id,
                  "content" => serialize_function_call_output_content(item.output)
                }
              when Items::Reasoning, Items::Compaction, Items::ItemReference
                # Reasoning, Compaction, and ItemReference items are not supported
                # in the request, so ignore them rather than raising an error.
                next
              end
            end

            flush_tool_calls!(messages, pending_tool_calls, last_assistant_msg)
            messages
          end

          def serialize_message(item)
            # Messages with an unsupported role are silently skipped.
            return nil unless SUPPORTED_MESSAGE_ROLES.include?(item.role)

            # RefusalContent can land in the session via a parsed Chat Completions
            # response; drop it silently so subsequent request_payload calls
            # don't fail mid-loop.
            visible_content = item.content.reject { |c| c.is_a?(Content::RefusalContent) }

            # Skip messages with no remaining content. For assistants with only
            # tool calls, flush_tool_calls! synthesizes a placeholder later.
            return nil if visible_content.empty?

            content = visible_content.filter_map { |c| serialize_content(item.role, c) }
            return nil if content.empty?

            {
              "role" => item.role,
              "content" => content
            }
          end

          def serialize_content(role, content)
            case content
            when Content::InputText, Content::OutputText
              serialize_text_content(content)
            when Content::InputImage
              # Image content is only supported in user messages; omit otherwise.
              return nil unless role == "user"

              serialize_image_content(content)
            when Content::InputFile
              # File content is only supported in user messages; omit otherwise.
              return nil unless role == "user"

              serialize_file_content(content)
            when Content::InputVideo
              # InputVideo content is not supported; omit it.
              nil
            when Content::RefusalContent
              # Filtered out in serialize_message; defensive no-op here.
              nil
            else
              # Unsupported content types are silently omitted.
              nil
            end
          end

          def serialize_function_call(item)
            {
              "id" => item.call_id,
              "type" => "function",
              "function" => {
                "name" => item.name,
                "arguments" => item.arguments
              }
            }
          end

          def serialize_function_call_output_content(output)
            return "" if output.nil?
            return output unless output.is_a?(Array)

            # Only text content is supported in tool output; other content types
            # are silently omitted.
            content = output.filter_map do |content|
              case content
              when Content::InputText, Content::OutputText
                serialize_text_content(content)
              end
            end

            # Chat Completions rejects tool messages with an empty content
            # array; collapse to an empty string like the other serializers.
            content.empty? ? "" : content
          end

          def flush_tool_calls!(messages, pending_tool_calls, last_assistant_msg = nil)
            return if pending_tool_calls.empty?

            if last_assistant_msg
              # Attach to the immediately preceding assistant message rather than emit a duplicate
              last_assistant_msg["tool_calls"] = pending_tool_calls.dup
            else
              messages << {
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => pending_tool_calls.dup
              }
            end
            pending_tool_calls.clear
          end

          def build_tools(session)
            session.tool_definitions.map do |definition|
              tool = {"type" => "function", "function" => {"name" => definition.name}}
              tool["function"]["description"] = definition.description if definition.description
              tool["function"]["parameters"] = definition.parameters if definition.parameters
              tool["function"]["strict"] = definition.strict if definition.strict
              tool
            end
          end

          # Unsupported tool_choice values (including a tool_choice that requires
          # tools when none are present) are silently omitted by returning nil.
          def serialize_tool_choice(choice, tools_empty)
            case choice
            when String
              return nil unless SUPPORTED_TOOL_CHOICE_VALUES.include?(choice)
              return nil if tools_empty && choice != "none"

              choice
            when Hash
              choice = normalize_hash(choice)

              return nil if choice["type"] != "function"
              return nil if tools_empty

              name = choice["name"] || choice.dig("function", "name")
              unless name
                raise UnsupportedFormatError, "tool_choice.function.name is required in Chat Completions format"
              end

              {"type" => "function", "function" => {"name" => name}}
            end
          end

          def serialize_text_content(content)
            # OutputText.annotations (e.g. URL citations from web_search_options)
            # are dropped silently — the canonical OR shape can carry them, but
            # Chat Completions has no request-side place to put them. Dropping
            # rather than raising lets a parsed response with citations sit in
            # session history without breaking subsequent request_payload calls.
            {"type" => "text", "text" => content.text}
          end

          def serialize_file_content(content)
            file_id = content.extra && content.extra["file_id"]
            media_type = content.extra && content.extra["media_type"]

            parsed = PromptBuilder.parse_data_url(content.url)
            mime = media_type || (parsed && parsed[0])

            # Text-based files are inlined as text content blocks since the Chat
            # Completions file type is not universally supported for text formats.
            if parsed && text_media_type?(mime)
              text = parsed[1].unpack1("m").force_encoding("utf-8")
              return {"type" => "text", "text" => text}
            end

            file = {}
            file["file_id"] = file_id if file_id
            file["filename"] = content.filename if content.filename

            if parsed
              file["file_data"] = "data:#{mime};base64,#{parsed[1]}"
            end

            # InputFile plain URLs have no Chat Completions representation. When a
            # usable source is present it is used; when a plain URL is the only
            # source, the block is omitted rather than raising.
            unless file["file_id"] || file["file_data"]
              return nil if content.url

              raise UnsupportedFormatError,
                "InputFile requires file_id (in extra) or data in Chat Completions format"
            end

            {"type" => "file", "file" => file}
          end

          def text_media_type?(media_type)
            return false unless media_type

            media_type.start_with?("text/") ||
              media_type == "application/json" ||
              media_type == "application/xml" ||
              media_type == "application/javascript" ||
              media_type == "application/yaml" ||
              media_type == "application/x-yaml" ||
              media_type == "application/csv" ||
              media_type == "application/xhtml+xml" ||
              media_type == "application/sql" ||
              media_type == "application/graphql" ||
              media_type == "application/ld+json" ||
              media_type.end_with?("+xml") ||
              media_type.end_with?("+json")
          end

          def serialize_image_content(content)
            url = content.url

            if url
              # InputImage file_id (in extra) is ignored: the image_file content
              # type is Assistants API only. url is used instead.
              image_url = {"url" => url}
              image_url["detail"] = content.detail if content.detail
              return {"type" => "image_url", "image_url" => image_url}
            end

            # No usable url. If file_id was provided, its only source is the
            # unsupported image_file content type, so omit the block.
            file_id = content.extra && content.extra["file_id"]
            return nil if file_id

            raise UnsupportedFormatError, "InputImage requires url in Chat Completions format"
          end

          def extract_response_format(format)
            return format unless format.is_a?(Hash) && format["type"] == "json_schema"
            return format if format["json_schema"].is_a?(Hash)

            # The Open Responses canonical shape puts name/schema/strict/description
            # flat under text.format; Chat Completions wraps them in a json_schema sub-object.
            json_schema = format.slice("name", "schema", "strict", "description")
            {"type" => "json_schema", "json_schema" => json_schema}
          end

          def normalize_hash(value)
            value.each_with_object({}) do |(key, nested_value), hash|
              hash[key.to_s] = nested_value.is_a?(Hash) ? normalize_hash(nested_value) : nested_value
            end
          end
        end
      end
    end
  end
end
