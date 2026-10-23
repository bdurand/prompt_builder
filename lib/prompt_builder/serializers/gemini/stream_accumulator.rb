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
      # in order, with adjacent text parts of the same kind (thought or not)
      # merged into one part that keeps the +thoughtSignature+; two parts that
      # both carry a signature stay separate. +functionCall+ and other parts
      # arrive whole. +citationMetadata.citationSources+ are concatenated, and
      # every other field (+finishReason+, +usageMetadata+, +modelVersion+,
      # +responseId+, ...) is taken from the last chunk that has it.
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
            else
              merged[key] = value
            end
          end
        end

        def merge_content(merged, content)
          target = merged["content"] ||= {"parts" => []}
          content.each { |key, value| target[key] = value unless key == "parts" || value.nil? }
          (content["parts"] || []).each { |part| append_part(target["parts"], part) if part.is_a?(Hash) }
        end

        def append_part(parts, part)
          last = parts.last
          if mergeable_text?(last, part)
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

        def build_result
          candidates = @candidates.sort_by { |index, _| index.to_i }.map { |_, candidate| candidate }
          blocked = @response.dig("promptFeedback", "blockReason")
          finished = !candidates.empty? && candidates.all? { |candidate| candidate["finishReason"] }
          incomplete!("Gemini stream ended without a finishReason") unless blocked || finished

          @response.merge("candidates" => candidates)
        end
      end
    end
  end
end
