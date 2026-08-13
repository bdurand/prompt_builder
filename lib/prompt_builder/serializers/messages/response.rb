# frozen_string_literal: true

require "json"

module PromptBuilder
  module Serializers
    class Messages < Base
      # Response parser for the Anthropic Messages API format.
      class Response < Base
        class << self
          private

          # Anthropic errors arrive as
          # {"type" => "error", "error" => {"type" => ..., "message" => ...}}.
          def error_response_message(hash)
            error = hash["error"]
            return nil unless error.is_a?(Hash) && !hash.key?("content")

            [error["type"], error["message"]].compact.join(": ")
          end

          def deserialize_response(hash, _headers = nil)
            require_response_key!(hash, "content")
            require_response_key!(hash, "stop_reason")

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
            inference_geo = usage_hash["inference_geo"]
            server_tool_use = usage_hash["server_tool_use"]

            input_tokens_details = input_tokens_details.merge("cache_creation_input_tokens" => cache_creation) if cache_creation
            input_tokens_details = input_tokens_details.merge("cached_tokens" => cache_read) if cache_read
            input_tokens_details = input_tokens_details.merge("cache_creation" => cache_creation_breakdown) if cache_creation_breakdown
            input_tokens_details = input_tokens_details.merge("service_tier" => service_tier) if service_tier
            input_tokens_details = input_tokens_details.merge("inference_geo" => inference_geo) if inference_geo
            input_tokens_details = input_tokens_details.merge("server_tool_use" => server_tool_use) if server_tool_use

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
            details["stop_details"] = hash["stop_details"] if hash["stop_details"]
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
                text_contents << Content::OutputText.new(
                  text: block["text"],
                  annotations: block["citations"] || []
                )
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
                # Unsupported content block types (e.g. built-in tool results)
                # are silently skipped rather than raising.
                next
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
