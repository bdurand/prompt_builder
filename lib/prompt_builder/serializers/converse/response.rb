# frozen_string_literal: true

require "json"

module PromptBuilder
  module Serializers
    class Converse < Base
      # Response parser for the Amazon Bedrock Converse API format.
      class Response < Base
        class << self
          private

          def deserialize_response(hash)
            usage_hash = hash["usage"]
            usage = if usage_hash
              cache_read = usage_hash["cacheReadInputTokens"]
              cache_write = usage_hash["cacheWriteInputTokens"]

              input_tokens_details = {}
              input_tokens_details["cached_tokens"] = cache_read if cache_read
              input_tokens_details["cache_creation_input_tokens"] = cache_write if cache_write

              Usage.new(
                input_tokens: usage_hash["inputTokens"],
                output_tokens: usage_hash["outputTokens"],
                total_tokens: usage_hash["totalTokens"],
                input_tokens_details: input_tokens_details.empty? ? nil : input_tokens_details
              )
            end

            message = hash.dig("output", "message") || {}
            content_blocks = message["content"] || []

            PromptBuilder::Response.new(
              id: nil,
              object: nil,
              model: nil,
              output: build_output_items(content_blocks),
              status: map_stop_reason(hash["stopReason"]),
              usage: usage,
              service_tier: hash.dig("serviceTier", "type"),
              extra: provider_data(hash)
            )
          end

          def map_stop_reason(reason)
            case reason
            when "end_turn", "tool_use", "stop_sequence"
              "completed"
            when "max_tokens"
              "incomplete"
            when "guardrail_intervened", "content_filtered"
              "failed"
            when "malformed_model_output", "malformed_tool_use"
              "failed"
            when "model_context_window_exceeded"
              "incomplete"
            else
              reason
            end
          end

          def provider_data(hash)
            data = {}
            %w[additionalModelResponseFields metrics performanceConfig serviceTier trace].each do |key|
              data[key] = hash[key] if hash[key]
            end
            data
          end

          def build_output_items(content_blocks)
            output = []
            text_contents = []
            reasoning_contents = []

            content_blocks.each do |block|
              if block["text"]
                flush_reasoning_contents!(output, reasoning_contents)
                text_contents << Content::OutputText.new(text: block["text"])
              elsif block["toolUse"]
                flush_text_contents!(output, text_contents)
                flush_reasoning_contents!(output, reasoning_contents)

                tool_use = block["toolUse"]
                output << Items::FunctionCall.new(
                  name: tool_use["name"],
                  call_id: tool_use["toolUseId"],
                  arguments: JSON.generate(tool_use["input"] || {})
                )
              elsif block["reasoningContent"]
                flush_text_contents!(output, text_contents)

                reasoning = block["reasoningContent"]
                if reasoning["reasoningText"]
                  thinking_block = {
                    "type" => "thinking",
                    "thinking" => reasoning["reasoningText"]["text"] || ""
                  }
                  signature = reasoning["reasoningText"]["signature"]
                  thinking_block["signature"] = signature if signature
                  reasoning_contents << thinking_block
                elsif reasoning["redactedContent"]
                  reasoning_contents << {
                    "type" => "redacted_thinking",
                    "data" => reasoning["redactedContent"]
                  }
                end
              else
                # Unrecognized content blocks (citationsContent, guardContent,
                # etc.) are silently skipped.
                next
              end
            end

            flush_text_contents!(output, text_contents)
            flush_reasoning_contents!(output, reasoning_contents)
            output
          end

          def flush_text_contents!(output, text_contents)
            return if text_contents.empty?

            output << Items::Message.new(
              role: "assistant",
              content: text_contents.dup
            )
            text_contents.clear
          end

          def flush_reasoning_contents!(output, reasoning_contents)
            return if reasoning_contents.empty?

            output << Items::Reasoning.new(content: reasoning_contents.dup)
            reasoning_contents.clear
          end
        end
      end
    end
  end
end
