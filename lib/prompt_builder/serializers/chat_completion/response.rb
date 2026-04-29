# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class ChatCompletion < Base
      # Response parser for the OpenAI Chat Completions API format.
      class Response < Base
        class << self
          private

          def deserialize_response(hash)
            output = []
            choice = hash.dig("choices", 0)

            if choice
              message = choice["message"] || {}
              logprobs_content = choice.dig("logprobs", "content") || []

              if message["refusal"]
                output << Items::Message.new(
                  role: "assistant",
                  content: [Content::RefusalContent.new(refusal: message["refusal"])]
                )
              elsif message["content"]
                output << Items::Message.new(
                  role: "assistant",
                  content: [Content::OutputText.new(text: message["content"], logprobs: logprobs_content)]
                )
              end

              (message["tool_calls"] || []).each do |tool_call|
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
              output: output,
              status: map_finish_reason(choice&.dig("finish_reason")),
              usage: usage
            )
          end

          def map_finish_reason(reason)
            case reason
            when "stop", "tool_calls"
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
