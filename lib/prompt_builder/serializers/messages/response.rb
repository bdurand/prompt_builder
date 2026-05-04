# frozen_string_literal: true

require "json"

module PromptBuilder
  module Serializers
    class Messages < Base
      # Response parser for the Anthropic Messages API format.
      class Response < Base
        class << self
          private

          def deserialize_response(hash)
            usage_hash = hash["usage"]
            usage = if usage_hash
              input_tokens_details = usage_hash["input_tokens_details"] || {}
              cache_creation = usage_hash["cache_creation_input_tokens"]
              cache_read = usage_hash["cache_read_input_tokens"]
              input_tokens_details = input_tokens_details.merge("cache_creation_input_tokens" => cache_creation) if cache_creation
              input_tokens_details = input_tokens_details.merge("cached_tokens" => cache_read) if cache_read

              # Anthropic reports input_tokens excluding cached/cache-creation tokens,
              # which are billed and counted separately. Include them in the total.
              total = usage_hash["input_tokens"].to_i + usage_hash["output_tokens"].to_i +
                cache_creation.to_i + cache_read.to_i

              Usage.new(
                input_tokens: usage_hash["input_tokens"],
                output_tokens: usage_hash["output_tokens"],
                total_tokens: total,
                input_tokens_details: input_tokens_details.empty? ? nil : input_tokens_details,
                output_tokens_details: usage_hash["output_tokens_details"]
              )
            end

            PromptBuilder::Response.new(
              id: hash["id"],
              object: hash["type"],
              model: hash["model"],
              output: build_output_items(hash["content"] || []),
              status: map_stop_reason(hash["stop_reason"]),
              usage: usage
            )
          end

          def map_stop_reason(reason)
            case reason
            when "end_turn", "tool_use"
              "completed"
            when "max_tokens"
              "incomplete"
            else
              reason
            end
          end

          def build_output_items(content_blocks)
            output = []
            text_contents = []
            reasoning_contents = []

            content_blocks.each do |block|
              case block["type"]
              when "text"
                flush_reasoning_contents!(output, reasoning_contents)
                text_contents << Content::OutputText.new(text: block["text"])
              when "tool_use"
                flush_text_contents!(output, text_contents)
                flush_reasoning_contents!(output, reasoning_contents)
                output << Items::FunctionCall.new(
                  name: block["name"],
                  call_id: block["id"],
                  arguments: JSON.generate(block["input"] || {})
                )
              when "thinking", "redacted_thinking"
                flush_text_contents!(output, text_contents)
                reasoning_contents << deserialize_reasoning_block(block)
              end
            end

            flush_text_contents!(output, text_contents)
            flush_reasoning_contents!(output, reasoning_contents)
            output
          end

          def deserialize_reasoning_block(block)
            case block["type"]
            when "thinking"
              {
                "type" => "thinking",
                "thinking" => block.fetch("thinking", ""),
                "signature" => block["signature"]
              }
            when "redacted_thinking"
              {
                "type" => "redacted_thinking",
                "data" => block["data"]
              }
            end
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
