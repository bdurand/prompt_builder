# frozen_string_literal: true

require "json"
require "securerandom"

module PromptBuilder
  module Serializers
    class Gemini < Base
      # Response parser for the Google Gemini API format.
      #
      # === Response metadata not modeled by Open Responses
      #
      # The Gemini response surface has fields with no canonical Open Responses
      # equivalent. The parser preserves them on +Response#extra+ rather
      # than dropping them silently:
      # - +groundingMetadata+ — web search grounding chunks, supports, queries
      # - +citationMetadata+ — per-candidate citation sources
      # - +urlContextMetadata+ / +urlRetrievalMetadata+ — URL retrieval traces
      # - +safetyRatings+ — per-candidate safety probabilities and severities
      # - +promptFeedback+ — prompt-level safety feedback
      # - +avgLogprobs+ / +logprobsResult+ — log-probability outputs
      # - +finishMessage+ — human-readable explanation of +finishReason+
      # - +createTime+ — RFC 3339 response creation timestamp
      # - +index+ — candidate index when +candidateCount+ > 1
      #
      # Additional +usageMetadata+ breakdowns (per-modality token counts and
      # tool-use prompt tokens) are surfaced through +Usage#input_tokens_details+
      # and +Usage#output_tokens_details+.
      #
      # === Unsupported response shapes
      #
      # The response parser raises +UnsupportedFormatError+ on +Part+ shapes
      # that have no canonical Open Responses equivalent so that lossless
      # round-tripping is preserved:
      # - +inlineData+ / +fileData+ parts (image/audio output blobs)
      # - +executableCode+ / +codeExecutionResult+ parts
      # - server-side +toolCall+ / +toolResponse+ parts
      # - +Part+s with no recognized content key
      class Response < Base
        FAILED_FINISH_REASONS = %w[
          SAFETY
          RECITATION
          OTHER
          BLOCKLIST
          PROHIBITED_CONTENT
          SPII
          MALFORMED_FUNCTION_CALL
          IMAGE_SAFETY
          LANGUAGE
          UNEXPECTED_TOOL_CALL
          TOO_MANY_TOOL_CALLS
          MODEL_ARMOR
          IMAGE_PROHIBITED_CONTENT
          IMAGE_OTHER
          NO_IMAGE
          IMAGE_RECITATION
          MISSING_THOUGHT_SIGNATURE
          MALFORMED_RESPONSE
        ].freeze
        private_constant :FAILED_FINISH_REASONS

        class << self
          private

          def deserialize_response(hash)
            usage = build_usage(hash["usageMetadata"])

            candidates = hash["candidates"] || []
            if candidates.length > 1
              raise UnsupportedFormatError,
                "Gemini format cannot parse multiple candidates into a single canonical Response"
            end

            first_candidate = candidates[0]

            response_id = hash["responseId"]
            call_id_seed = response_id || SecureRandom.hex(4)

            output_items = if first_candidate && first_candidate["content"]
              build_output_items(first_candidate["content"]["parts"] || [], call_id_seed)
            else
              []
            end

            finish_reason = first_candidate ? first_candidate["finishReason"] : nil
            status = map_finish_reason(finish_reason)

            # When candidates is empty due to a prompt-level safety block, Gemini
            # returns an empty `candidates` and a `promptFeedback.blockReason`.
            # Surface that as a failed status rather than silently nil.
            if status.nil? && candidates.empty? && hash.dig("promptFeedback", "blockReason")
              status = "failed"
            end

            provider_data = build_provider_data(hash, first_candidate)

            PromptBuilder::Response.new(
              id: response_id,
              object: nil,
              model: hash["modelVersion"],
              output: output_items,
              status: status,
              usage: usage,
              extra: provider_data
            )
          end

          def build_usage(usage_hash)
            return nil unless usage_hash

            input_tokens_details = {}
            input_tokens_details["cached_tokens"] = usage_hash["cachedContentTokenCount"] if usage_hash["cachedContentTokenCount"]
            input_tokens_details["tool_use_prompt_tokens"] = usage_hash["toolUsePromptTokenCount"] if usage_hash["toolUsePromptTokenCount"]
            input_tokens_details["prompt_tokens_details"] = usage_hash["promptTokensDetails"] if usage_hash["promptTokensDetails"]
            input_tokens_details["cache_tokens_details"] = usage_hash["cacheTokensDetails"] if usage_hash["cacheTokensDetails"]
            input_tokens_details["tool_use_prompt_tokens_details"] = usage_hash["toolUsePromptTokensDetails"] if usage_hash["toolUsePromptTokensDetails"]

            output_tokens_details = {}
            output_tokens_details["reasoning_tokens"] = usage_hash["thoughtsTokenCount"] if usage_hash["thoughtsTokenCount"]
            output_tokens_details["candidates_tokens_details"] = usage_hash["candidatesTokensDetails"] if usage_hash["candidatesTokensDetails"]

            Usage.new(
              input_tokens: usage_hash["promptTokenCount"],
              output_tokens: usage_hash["candidatesTokenCount"],
              total_tokens: usage_hash["totalTokenCount"],
              input_tokens_details: input_tokens_details.empty? ? nil : input_tokens_details,
              output_tokens_details: output_tokens_details.empty? ? nil : output_tokens_details
            )
          end

          def build_provider_data(hash, candidate)
            data = {}
            data["create_time"] = hash["createTime"] if hash["createTime"]
            data["model_status"] = hash["modelStatus"] if hash["modelStatus"]
            data["prompt_feedback"] = hash["promptFeedback"] if hash["promptFeedback"]

            if candidate
              data["index"] = candidate["index"] if candidate.key?("index")
              data["safety_ratings"] = candidate["safetyRatings"] if candidate["safetyRatings"]
              data["citation_metadata"] = candidate["citationMetadata"] if candidate["citationMetadata"]
              data["grounding_metadata"] = candidate["groundingMetadata"] if candidate["groundingMetadata"]
              data["url_context_metadata"] = candidate["urlContextMetadata"] if candidate["urlContextMetadata"]
              data["url_retrieval_metadata"] = candidate["urlRetrievalMetadata"] if candidate["urlRetrievalMetadata"]
              data["avg_logprobs"] = candidate["avgLogprobs"] if candidate.key?("avgLogprobs")
              data["logprobs_result"] = candidate["logprobsResult"] if candidate["logprobsResult"]
              data["grounding_attributions"] = candidate["groundingAttributions"] if candidate["groundingAttributions"]
              data["finish_message"] = candidate["finishMessage"] if candidate["finishMessage"]
            end

            data.empty? ? nil : data
          end

          def map_finish_reason(reason)
            case reason
            when nil, "FINISH_REASON_UNSPECIFIED"
              nil
            when "STOP"
              "completed"
            when "MAX_TOKENS"
              "incomplete"
            when *FAILED_FINISH_REASONS
              "failed"
            else
              reason
            end
          end

          def build_output_items(parts, call_id_seed)
            output = []
            text_contents = []
            reasoning_contents = []
            call_index = 0

            parts.each do |part|
              if part["thought"]
                flush_text_contents!(output, text_contents)
                block = {
                  "type" => "thinking",
                  "thinking" => part["text"] || ""
                }
                block["signature"] = part["thoughtSignature"] if part["thoughtSignature"]
                reasoning_contents << block
              elsif part["functionCall"]
                flush_text_contents!(output, text_contents)
                flush_reasoning_contents!(output, reasoning_contents)

                function_call = part["functionCall"]
                call_id = function_call["id"] || "gemini_call_#{call_id_seed}_#{call_index}"

                output << Items::FunctionCall.new(
                  name: function_call["name"],
                  call_id: call_id,
                  arguments: JSON.generate(function_call["args"] || {}),
                  **(part["thoughtSignature"] ? {thought_signature: part["thoughtSignature"]} : {})
                )
                call_index += 1
              elsif part.key?("text")
                flush_reasoning_contents!(output, reasoning_contents)
                text_contents << Content::OutputText.new(
                  text: part["text"],
                  **(part["thoughtSignature"] ? {thought_signature: part["thoughtSignature"]} : {})
                )
              else
                raise UnsupportedFormatError,
                  "Gemini format cannot parse response part #{describe_part(part)}; " \
                  "no canonical Open Responses equivalent. Drop the part from the " \
                  "raw response or extend the parser."
              end
            end

            flush_text_contents!(output, text_contents)
            flush_reasoning_contents!(output, reasoning_contents)
            output
          end

          def describe_part(part)
            recognized = part.keys.find do |k|
              %w[inlineData fileData executableCode codeExecutionResult videoMetadata toolCall toolResponse].include?(k)
            end
            return recognized.inspect if recognized

            "with keys #{part.keys.inspect}"
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
