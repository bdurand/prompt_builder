# frozen_string_literal: true

require "json"

module PromptBuilder
  module Serializers
    class Gemini < Base
      # Response parser for the Google Gemini API format.
      class Response < Base
        class << self
          private

          def deserialize_response(hash)
            usage_hash = hash["usageMetadata"]
            usage = if usage_hash
              input_tokens_details = {}
              input_tokens_details["cached_tokens"] = usage_hash["cachedContentTokenCount"] if usage_hash["cachedContentTokenCount"]

              output_tokens_details = {}
              output_tokens_details["reasoning_tokens"] = usage_hash["thoughtsTokenCount"] if usage_hash["thoughtsTokenCount"]

              Usage.new(
                input_tokens: usage_hash["promptTokenCount"],
                output_tokens: usage_hash["candidatesTokenCount"],
                total_tokens: usage_hash["totalTokenCount"],
                input_tokens_details: input_tokens_details.empty? ? nil : input_tokens_details,
                output_tokens_details: output_tokens_details.empty? ? nil : output_tokens_details
              )
            end

            candidates = hash["candidates"] || []
            first_candidate = candidates[0]

            output_items = if first_candidate && first_candidate["content"]
              build_output_items(first_candidate["content"]["parts"] || [])
            else
              []
            end

            finish_reason = first_candidate ? first_candidate["finishReason"] : nil

            PromptBuilder::Response.new(
              id: nil,
              object: nil,
              model: hash["modelVersion"],
              output: output_items,
              status: map_finish_reason(finish_reason),
              usage: usage
            )
          end

          def map_finish_reason(reason)
            case reason
            when "STOP"
              "completed"
            when "MAX_TOKENS"
              "incomplete"
            when "SAFETY", "RECITATION", "OTHER"
              "failed"
            else
              reason
            end
          end

          def build_output_items(parts)
            output = []
            text_contents = []
            reasoning_contents = []
            call_index = 0

            parts.each do |part|
              if part["thought"]
                flush_text_contents!(output, text_contents)
                reasoning_contents << {
                  "type" => "thinking",
                  "thinking" => part["text"] || ""
                }
              elsif part["functionCall"]
                flush_text_contents!(output, text_contents)
                flush_reasoning_contents!(output, reasoning_contents)

                function_call = part["functionCall"]
                output << Items::FunctionCall.new(
                  name: function_call["name"],
                  call_id: "gemini_call_#{call_index}",
                  arguments: JSON.generate(function_call["args"] || {})
                )
                call_index += 1
              elsif part["text"]
                flush_reasoning_contents!(output, reasoning_contents)
                text_contents << Content::OutputText.new(text: part["text"])
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
