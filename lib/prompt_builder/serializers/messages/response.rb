# frozen_string_literal: true

require "json"

module PromptBuilder
  module Serializers
    class Messages < Base
      # Response parser for the Anthropic Messages API format.
      class Response < Base
        class << self
          private

          # Anthropic content block types this gem understands and parses
          # back into canonical items.
          KNOWN_CONTENT_BLOCK_TYPES = %w[text tool_use thinking redacted_thinking].freeze
          private_constant :KNOWN_CONTENT_BLOCK_TYPES

          # Anthropic content block types produced by built-in tools that this
          # gem does not model. Listed explicitly so the error message tells
          # the user what they hit (rather than just "unknown type").
          BUILT_IN_TOOL_BLOCK_TYPES = %w[
            server_tool_use
            web_search_tool_result
            code_execution_tool_result
            mcp_tool_use
            mcp_tool_result
            container_upload
            search_result
          ].freeze
          private_constant :BUILT_IN_TOOL_BLOCK_TYPES

          def deserialize_response(hash)
            usage_hash = hash["usage"]
            usage = build_usage(usage_hash) if usage_hash

            PromptBuilder::Response.new(
              id: hash["id"],
              object: hash["type"],
              model: hash["model"],
              output: build_output_items(hash["content"] || []),
              status: map_stop_reason(hash["stop_reason"]),
              incomplete_details: build_incomplete_details(hash),
              usage: usage
            )
          end

          def build_usage(usage_hash)
            input_tokens_details = usage_hash["input_tokens_details"] || {}
            cache_creation = usage_hash["cache_creation_input_tokens"]
            cache_read = usage_hash["cache_read_input_tokens"]
            cache_creation_breakdown = usage_hash["cache_creation"]
            service_tier = usage_hash["service_tier"]

            input_tokens_details = input_tokens_details.merge("cache_creation_input_tokens" => cache_creation) if cache_creation
            input_tokens_details = input_tokens_details.merge("cached_tokens" => cache_read) if cache_read
            input_tokens_details = input_tokens_details.merge("cache_creation" => cache_creation_breakdown) if cache_creation_breakdown
            input_tokens_details = input_tokens_details.merge("service_tier" => service_tier) if service_tier

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

          def build_incomplete_details(hash)
            details = {}
            details["stop_sequence"] = hash["stop_sequence"] if hash["stop_sequence"]
            details["container"] = hash["container"] if hash["container"]
            details.empty? ? nil : details
          end

          # Anthropic stop_reason values:
          # - end_turn, tool_use, stop_sequence, pause_turn → completed
          # - max_tokens → incomplete (truncated mid-output)
          # - refusal → failed (model declined to respond)
          # - anything else → pass through unchanged so callers can inspect it
          def map_stop_reason(reason)
            case reason
            when "end_turn", "tool_use", "stop_sequence", "pause_turn"
              "completed"
            when "max_tokens"
              "incomplete"
            when "refusal"
              "failed"
            else
              reason
            end
          end

          def build_output_items(content_blocks)
            output = []
            text_contents = []
            reasoning_contents = []

            content_blocks.each do |block|
              type = block["type"]
              case type
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
              else
                raise UnsupportedFormatError, unsupported_block_message(type)
              end
            end

            flush_text_contents!(output, text_contents)
            flush_reasoning_contents!(output, reasoning_contents)
            output
          end

          def unsupported_block_message(type)
            if BUILT_IN_TOOL_BLOCK_TYPES.include?(type)
              "Messages format cannot parse #{type.inspect} content blocks " \
                "(produced by Anthropic built-in tools such as web search, code execution, " \
                "MCP, computer use, or container uploads). These features are not modeled " \
                "by this gem; remove the corresponding tool from the request or parse the " \
                "response with a provider-specific parser."
            else
              "Messages format does not recognize content block type #{type.inspect}; " \
                "known types are #{KNOWN_CONTENT_BLOCK_TYPES.join(", ")}"
            end
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
