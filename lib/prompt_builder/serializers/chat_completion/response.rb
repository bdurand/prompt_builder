# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class ChatCompletion < Base
      # Response parser for the OpenAI Chat Completions API format.
      #
      # Responses with multiple choices (+n > 1+) parse only the first choice;
      # the canonical response object has no candidate collection. Audio
      # responses, legacy +function_call+ responses, non-function tool calls,
      # and unknown content block types are silently skipped. Streaming chunks
      # (+chat.completion.chunk+ deltas) raise +UnsupportedFormatError+ — this
      # parser expects a fully assembled non-streaming response body.
      # Top-level +system_fingerprint+ is exposed through +extra+.
      class Response < Base
        class << self
          private

          def deserialize_response(hash)
            validate_response!(hash)

            output = []
            choice = hash.dig("choices", 0)

            if choice
              message = choice["message"] || {}
              logprobs_content = choice.dig("logprobs", "content") || []
              annotations = message["annotations"] || []

              # Audio responses and legacy function_call responses are not
              # modeled; they are silently ignored.

              if message["refusal"]
                output << Items::Message.new(
                  role: "assistant",
                  content: [Content::RefusalContent.new(refusal: message["refusal"])]
                )
              elsif message["content"].is_a?(Array)
                # logprobs and annotations are reported once per message, so
                # attach them to the first text block only to avoid duplicating
                # them across blocks on round-trip.
                first_text_block = true
                contents = message["content"].each_with_object([]) do |block, acc|
                  case block["type"]
                  when "text", nil
                    text = block["text"] || ""
                    next if text.empty?

                    acc << Content::OutputText.new(
                      text: text,
                      logprobs: first_text_block ? logprobs_content : [],
                      annotations: first_text_block ? annotations : []
                    )
                    first_text_block = false
                  when "refusal"
                    acc << Content::RefusalContent.new(refusal: block["refusal"]) if block["refusal"]
                  else
                    # Unsupported content block types are silently skipped.
                    next
                  end
                end
                output << Items::Message.new(role: "assistant", content: contents) unless contents.empty?
              elsif message["content"] && !message["content"].empty?
                output << Items::Message.new(
                  role: "assistant",
                  content: [Content::OutputText.new(
                    text: message["content"],
                    logprobs: logprobs_content,
                    annotations: annotations
                  )]
                )
              end

              (message["tool_calls"] || []).each do |tool_call|
                # Non-function tool call types are silently skipped.
                next unless tool_call["type"] == "function"

                function = tool_call["function"] || {}
                output << Items::FunctionCall.new(
                  name: function["name"],
                  call_id: tool_call["id"],
                  arguments: function["arguments"] || "{}"
                )
              end
            end

            usage_hash = hash["usage"]
            usage = if usage_hash
              Usage.new(
                input_tokens: usage_hash["prompt_tokens"],
                output_tokens: usage_hash["completion_tokens"],
                total_tokens: usage_hash["total_tokens"],
                input_tokens_details: usage_hash["prompt_tokens_details"],
                output_tokens_details: usage_hash["completion_tokens_details"]
              )
            end

            PromptBuilder::Response.new(
              id: hash["id"],
              object: hash["object"],
              created_at: hash["created"],
              model: hash["model"],
              service_tier: hash["service_tier"],
              output: output,
              status: map_finish_reason(choice&.dig("finish_reason")),
              usage: usage,
              extra: provider_data(hash)
            )
          end

          def validate_response!(hash)
            # A streaming chunk is not a complete response body, so it cannot be
            # parsed into a canonical Response.
            if hash["object"] == "chat.completion.chunk"
              raise UnsupportedFormatError, "Chat Completions streaming chunks are not supported"
            end
            require_response_key!(hash, "choices")
            require_response_key!(hash, "model")
            # Responses with multiple choices have no canonical multi-candidate
            # representation; only the first choice is parsed (handled by the
            # caller using choices[0]).
          end

          def provider_data(hash)
            data = {}
            data["system_fingerprint"] = hash["system_fingerprint"] if hash["system_fingerprint"]
            data.empty? ? nil : data
          end

          def map_finish_reason(reason)
            case reason
            when "stop", "tool_calls", "function_call"
              "completed"
            when "length"
              "incomplete"
            when "content_filter"
              "failed"
            else
              reason
            end
          end
        end
      end
    end
  end
end
