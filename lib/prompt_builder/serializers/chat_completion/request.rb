# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class ChatCompletion < Base
      # Request serializer for the OpenAI Chat Completions API format.
      #
      # === Unsupported Open Responses features
      #
      # These session fields are not supported and raise +UnsupportedFormatError+:
      # - +background+ — Chat Completions has no background/async mode
      # - +include+ — response-field inclusion is an Open Responses-only concept
      # - +max_tool_calls+ — per-request tool-call caps are not supported
      # - +prompt_cache_key+ — explicit prompt cache keys are not supported
      # - +truncation+ — server-side context truncation is not supported
      #
      # Partially supported session fields (unsupported keys raise +UnsupportedFormatError+):
      # - +text+ — only the +format+ key is mapped to +response_format+
      # - +reasoning+ — only the +effort+ key is mapped to +reasoning_effort+
      # - +stream_options+ — only +include_usage+ and +include_obfuscation+ are supported
      #
      # Input content restrictions:
      # - +InputFile+ content is not supported in any message
      # - +InputVideo+ content is not supported in any message
      # - +Reasoning+ items are not supported
      # - +RefusalContent+ is not supported in request messages
      # - +InputImage+ content is only supported in user messages (not assistant/developer/system)
      # - Only text content is supported in tool (+FunctionCallOutput+) results
      # - +OutputText+ with annotations is not supported
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
      class Request < Base
        SUPPORTED_MESSAGE_ROLES = %w[assistant developer system user].freeze
        SUPPORTED_REASONING_KEYS = %w[effort].freeze
        SUPPORTED_STREAM_OPTION_KEYS = %w[include_obfuscation include_usage].freeze
        SUPPORTED_TEXT_KEYS = %w[format].freeze
        SUPPORTED_TOOL_CHOICE_VALUES = %w[auto none required].freeze

        class << self
          private

          def serialize_request(session)
            validate_session!(session)

            h = {}
            h["model"] = session.model if session.model
            h["messages"] = build_messages(session)
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
            h["user"] = session.safety_identifier if session.safety_identifier
            h["stream"] = session.stream unless session.stream.nil?
            h["stream_options"] = normalize_hash(session.stream_options) if session.stream_options
            h["response_format"] = extract_response_format(session.text) if session.text

            if session.reasoning
              h["reasoning_effort"] = normalize_hash(session.reasoning)["effort"] if normalize_hash(session.reasoning)["effort"]
            end

            tools = build_tools(session)
            h["tools"] = tools unless tools.empty?

            if !session.parallel_tool_calls.nil? && tools.empty?
              raise UnsupportedFormatError, "parallel_tool_calls requires at least one tool in Chat Completions format"
            end

            if session.tool_choice
              h["tool_choice"] = serialize_tool_choice(session.tool_choice, tools.empty?)
            end

            h
          end

          def validate_session!(session)
            raise_unsupported_field!("include") if session.include
            raise_unsupported_field!("background") unless session.background.nil?
            raise_unsupported_field!("max_tool_calls") if session.max_tool_calls
            raise_unsupported_field!("prompt_cache_key") if session.prompt_cache_key
            raise_unsupported_field!("truncation") if session.truncation

            validate_hash_keys!(session.text, SUPPORTED_TEXT_KEYS, "text") if session.text
            validate_hash_keys!(session.reasoning, SUPPORTED_REASONING_KEYS, "reasoning") if session.reasoning

            return unless session.stream_options

            unless session.stream
              raise UnsupportedFormatError, "stream_options requires stream: true in Chat Completions format"
            end

            validate_hash_keys!(session.stream_options, SUPPORTED_STREAM_OPTION_KEYS, "stream_options")
          end

          def build_messages(session)
            messages = []

            if session.instructions
              messages << {"role" => "system", "content" => session.instructions}
            end

            pending_tool_calls = []

            session.items.each do |item|
              case item
              when Items::Message
                flush_tool_calls!(messages, pending_tool_calls)
                messages << serialize_message(item)
              when Items::FunctionCall
                pending_tool_calls << serialize_function_call(item)
              when Items::FunctionCallOutput
                flush_tool_calls!(messages, pending_tool_calls)
                messages << {
                  "role" => "tool",
                  "tool_call_id" => item.call_id,
                  "content" => serialize_function_call_output_content(item.output)
                }
              when Items::Reasoning
                raise UnsupportedFormatError, "Reasoning items are not supported in Chat Completions format"
              end
            end

            flush_tool_calls!(messages, pending_tool_calls)
            messages
          end

          def serialize_message(item)
            unless SUPPORTED_MESSAGE_ROLES.include?(item.role)
              raise UnsupportedFormatError, "Unsupported message role for Chat Completions format: #{item.role}"
            end

            {
              "role" => item.role,
              "content" => item.content.map { |content| serialize_content(item.role, content) }
            }
          end

          def serialize_content(role, content)
            case content
            when Content::InputText, Content::OutputText
              serialize_text_content(content)
            when Content::InputImage
              unless role == "user"
                raise UnsupportedFormatError,
                  "#{role} messages do not support #{content.class.name.split("::").last} content in Chat Completions format"
              end

              serialize_image_content(content)
            when Content::InputFile
              raise UnsupportedFormatError, "InputFile is not supported in Chat Completions format"
            when Content::InputVideo
              raise UnsupportedFormatError, "InputVideo is not supported in Chat Completions format"
            when Content::RefusalContent
              raise UnsupportedFormatError, "RefusalContent is not supported in Chat Completions request format"
            else
              raise UnsupportedFormatError, "Unsupported content type: #{content.class}"
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
            return output unless output.is_a?(Array)

            output.map do |content|
              case content
              when Content::InputText, Content::OutputText
                serialize_text_content(content)
              else
                raise UnsupportedFormatError,
                  "#{content.class.name.split("::").last} is not supported in tool output in Chat Completions format"
              end
            end
          end

          def flush_tool_calls!(messages, pending_tool_calls)
            return if pending_tool_calls.empty?

            messages << {
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => pending_tool_calls.dup
            }
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

          def serialize_tool_choice(choice, tools_empty)
            case choice
            when String
              unless SUPPORTED_TOOL_CHOICE_VALUES.include?(choice)
                raise UnsupportedFormatError, "Unsupported tool_choice for Chat Completions format: #{choice.inspect}"
              end

              if tools_empty && choice != "none"
                raise UnsupportedFormatError, "tool_choice requires at least one tool in Chat Completions format"
              end

              choice
            when Hash
              choice = normalize_hash(choice)

              if choice["type"] != "function"
                raise UnsupportedFormatError, "Unsupported tool_choice for Chat Completions format: #{choice.inspect}"
              end

              if tools_empty
                raise UnsupportedFormatError, "tool_choice requires at least one tool in Chat Completions format"
              end

              name = choice["name"] || choice.dig("function", "name")
              unless name
                raise UnsupportedFormatError, "tool_choice.function.name is required in Chat Completions format"
              end

              {"type" => "function", "function" => {"name" => name}}
            else
              raise UnsupportedFormatError, "Unsupported tool_choice for Chat Completions format: #{choice.inspect}"
            end
          end

          def serialize_text_content(content)
            if content.is_a?(Content::OutputText) && !content.annotations.empty?
              raise UnsupportedFormatError, "OutputText annotations are not supported in Chat Completions format"
            end

            {"type" => "text", "text" => content.text}
          end

          def serialize_image_content(content)
            url = content.image_url
            if content.data
              unless content.media_type
                raise UnsupportedFormatError,
                  "InputImage media_type is required when using base64 data in Chat Completions format"
              end

              url = "data:#{content.media_type};base64,#{content.data}"
            end

            unless url
              raise UnsupportedFormatError, "InputImage requires image_url or data in Chat Completions format"
            end

            image_url = {"url" => url}
            image_url["detail"] = content.detail if content.detail
            {"type" => "image_url", "image_url" => image_url}
          end

          def extract_response_format(text)
            normalize_hash(text)["format"]
          end

          def normalize_hash(value)
            value.each_with_object({}) do |(key, nested_value), hash|
              hash[key.to_s] = nested_value.is_a?(Hash) ? normalize_hash(nested_value) : nested_value
            end
          end

          def raise_unsupported_field!(field_name)
            raise UnsupportedFormatError, "#{field_name} is not supported in Chat Completions format"
          end

          def validate_hash_keys!(value, supported_keys, field_name)
            normalize_hash(value).each_key do |key|
              next if supported_keys.include?(key)

              raise UnsupportedFormatError, "#{field_name}.#{key} is not supported in Chat Completions format"
            end
          end
        end
      end
    end
  end
end
