# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class Gemini < Base
      # Reassembles a Gemini +streamGenerateContent+ stream into the
      # +GenerateContentResponse+ the non-streaming +generateContent+ endpoint
      # would have returned.
      #
      # With +alt=sse+ each event is a complete +GenerateContentResponse+
      # chunk. Candidates are merged by +index+: their parts are concatenated
      # in order, and a text part that starts a chunk continues the text part
      # that ended the previous chunk when both are the same kind (thought or
      # not), keeping the +thoughtSignature+; two parts that both carry a
      # signature stay separate. Parts within one chunk are distinct parts and
      # are never merged with each other. A part with only a
      # +thoughtSignature+ and no text is the signature for the text before it,
      # so it is attached to that text part. +functionCall+ and other parts
      # arrive whole. +citationMetadata.citationSources+ and the
      # +logprobsResult+ token lists are concatenated (with +logProbabilitySum+
      # recomputed from the chosen tokens), and every other field
      # (+finishReason+, +usageMetadata+, +modelVersion+, +responseId+, ...) is
      # taken from the last chunk that has it.
      #
      # Without +alt=sse+ the endpoint returns a JSON array of the same chunks;
      # it is buffered whole and merged the same way.
      #
      # Gemini sends no terminal event, so a stream whose candidates have no
      # +finishReason+ (and that was not blocked by +promptFeedback.blockReason+)
      # is incomplete. A chunk with an +error+ raises an ErrorResponseError.
      class StreamAccumulator < Streaming::Accumulator
        TEXT_PART_KEYS = %w[text thought thoughtSignature].freeze
        private_constant :TEXT_PART_KEYS

        LOGPROBS_TOKEN_LISTS = %w[topCandidates chosenCandidates].freeze
        private_constant :LOGPROBS_TOKEN_LISTS

        def initialize
          super
          @response = {}
          @candidates = {}
        end

        private

        def handle_event(event)
          merge_chunk(parse_json(event.data))
        end

        def collapse_json(value)
          return value unless value.is_a?(Array)

          value.each { |chunk| merge_chunk(chunk) }
          build_result
        end

        def merge_chunk(chunk)
          return unless chunk.is_a?(Hash)

          if chunk["error"].is_a?(Hash)
            error = chunk["error"]
            raise_error_event!([error["status"] || error["code"], error["message"]].compact.join(": "))
          end

          chunk.each do |key, value|
            next if value.nil?

            if key == "candidates"
              value.each_with_index { |candidate, position| merge_candidate(candidate, position) if candidate.is_a?(Hash) }
            else
              @response[key] = value
            end
          end
        end

        def merge_candidate(candidate, position)
          merged = @candidates[candidate["index"] || position] ||= {}
          candidate.each do |key, value|
            next if value.nil?

            case key
            when "content"
              merge_content(merged, value) if value.is_a?(Hash)
            when "citationMetadata"
              merge_citation_metadata(merged, value) if value.is_a?(Hash)
            when "logprobsResult"
              merge_logprobs_result(merged, value) if value.is_a?(Hash)
            else
              merged[key] = value
            end
          end
        end

        def merge_content(merged, content)
          target = merged["content"] ||= {"parts" => []}
          content.each { |key, value| target[key] = value unless key == "parts" || value.nil? }
          parts = (content["parts"] || []).select { |part| part.is_a?(Hash) }
          parts.each_with_index { |part, position| append_part(target["parts"], part, continuation: position.zero?) }
        end

        # Only the first part of a chunk can continue text from the previous
        # chunk; later parts in the same chunk are separate parts in the
        # response, so they keep their own boundaries and signatures.
        def append_part(parts, part, continuation:)
          last = parts.last
          if signature_only?(part) && text_part?(last) && !last["thoughtSignature"]
            last["thoughtSignature"] = part["thoughtSignature"]
          elsif continuation && mergeable_text?(last, part)
            last["text"] << part["text"]
            last["thoughtSignature"] = part["thoughtSignature"] if part["thoughtSignature"]
          elsif text_part?(part)
            parts << part.merge("text" => +part["text"])
          else
            parts << part
          end
        end

        def mergeable_text?(last, part)
          return false unless text_part?(last) && text_part?(part)
          return false unless !!last["thought"] == !!part["thought"]

          !(last["thoughtSignature"] && part["thoughtSignature"])
        end

        def text_part?(part)
          part.is_a?(Hash) && part["text"].is_a?(String) && (part.keys - TEXT_PART_KEYS).empty?
        end

        def signature_only?(part)
          part["thoughtSignature"].is_a?(String) && !part.key?("text") && (part.keys - TEXT_PART_KEYS).empty?
        end

        def merge_citation_metadata(merged, metadata)
          target = merged["citationMetadata"] ||= {}
          metadata.each do |key, value|
            if key == "citationSources" && value.is_a?(Array)
              (target[key] ||= []).concat(value)
            elsif !value.nil?
              target[key] = value
            end
          end
        end

        # Each chunk reports log probabilities for its own tokens, so the
        # token lists are concatenated in order. The sum is recomputed for the
        # whole candidate once the stream ends (see #recompute_logprobs_sum).
        def merge_logprobs_result(merged, result)
          target = merged["logprobsResult"] ||= {}
          result.each do |key, value|
            if LOGPROBS_TOKEN_LISTS.include?(key) && value.is_a?(Array)
              (target[key] ||= []).concat(value)
            elsif !value.nil?
              target[key] = value
            end
          end
        end

        def recompute_logprobs_sum(candidate)
          result = candidate["logprobsResult"]
          return unless result&.key?("logProbabilitySum")

          chosen = result["chosenCandidates"]
          return unless chosen

          result["logProbabilitySum"] = chosen.sum { |token| token.is_a?(Hash) ? token["logProbability"].to_f : 0.0 }
        end

        def build_result
          candidates = @candidates.sort_by { |index, _| index.to_i }.map { |_, candidate| candidate }
          blocked = @response.dig("promptFeedback", "blockReason")
          finished = !candidates.empty? && candidates.all? { |candidate| finished_candidate?(candidate) }
          incomplete!("Gemini stream ended without a finishReason") unless blocked || finished

          candidates.each { |candidate| recompute_logprobs_sum(candidate) }
          @response.merge("candidates" => candidates)
        end

        # FINISH_REASON_UNSPECIFIED is the API's default value, which the
        # response parser treats as no finish reason, so it does not mark a
        # candidate as finished either.
        def finished_candidate?(candidate)
          reason = candidate["finishReason"]
          !reason.nil? && reason != "FINISH_REASON_UNSPECIFIED"
        end
      end
    end
  end
end
