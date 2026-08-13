# frozen_string_literal: true

require "json"

module PromptBuilder
  module Serializers
    class Converse < Base
      # Response parser for the Amazon Bedrock Converse API format.
      class Response < Base
        # The response id header set by Bedrock (the AWS request metadata id).
        RESPONSE_ID_HEADER = "x-amzn-requestid"

        class << self
          # Parse a Converse response into a PromptBuilder::Response. The
          # Converse API does not include a response id in the body; Bedrock
          # returns it in the request metadata headers, so the id is read
          # from +headers+ when they are given.
          #
          # @param hash [Hash] the response hash in Converse format
          # @param headers [Hash, #each, nil] the HTTP response headers
          # @return [PromptBuilder::Response] the parsed response
          # @raise [ErrorResponseError] if the payload is an API error envelope
          def parse_response(hash, headers: nil)
            check_error_response!(hash)
            deserialize_response(hash, headers)
          end

          private

          # Bedrock exception bodies carry a top-level "message" (the exception
          # class travels in the x-amzn-ErrorType header) or a top-level
          # "__type", while misrouted requests get a Coral service envelope
          # like {"Output" => {"__type" => "..."}, "Version" => "1.0"}.
          def error_response_message(hash)
            return nil if hash.key?("output")

            coral_output = hash["Output"].is_a?(Hash) ? hash["Output"] : {}
            error_type = hash["__type"] || coral_output["__type"]
            message = hash["message"] || hash["Message"] || coral_output["message"] || coral_output["Message"]
            return nil unless error_type || message

            [error_type, message].compact.join(": ")
          end

          def deserialize_response(hash, headers = nil)
            require_response_key!(hash, "output")
            require_response_key!(hash, "stopReason")

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
              id: response_id_from_headers(headers),
              object: nil,
              model: nil,
              output: build_output_items(content_blocks),
              status: map_stop_reason(hash["stopReason"]),
              usage: usage,
              service_tier: hash.dig("serviceTier", "type"),
              extra: provider_data(hash)
            )
          end

          # Find the response id header with a case-insensitive name match.
          # Header values may be scalars or arrays of values, depending on
          # the HTTP client the headers come from.
          def response_id_from_headers(headers)
            return nil unless headers.respond_to?(:each)

            headers.each do |name, value|
              next unless name.to_s.casecmp?(RESPONSE_ID_HEADER)

              value = value.first if value.is_a?(Array)
              value = value.to_s.strip
              return value unless value.empty?
            end
            nil
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
