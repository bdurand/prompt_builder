# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class ChatCompletion < Base
      # Reassembles an OpenAI Chat Completions SSE stream of
      # +chat.completion.chunk+ objects into the +chat.completion+ object the
      # non-streaming endpoint would have returned.
      #
      # Choice deltas are merged by +choices[].index+ into a +message+:
      # +content+, +refusal+, and other string fields are concatenated, and
      # +tool_calls+ fragments are merged by their own +index+, with +id+,
      # +type+, and +function.name+ taken as they appear and
      # +function.arguments+ concatenated. +finish_reason+ comes from the chunk
      # that carries it, and +logprobs+ arrays are concatenated. Usage arrives
      # in a final chunk with empty +choices+, and only when the request set
      # +stream_options.include_usage+.
      #
      # The stream must end with +data: [DONE]+; a chunk with an +error+ raises
      # an ErrorResponseError.
      class StreamAccumulator < Streaming::Accumulator
        DONE = "[DONE]"
        private_constant :DONE

        def initialize
          super
          @response = {}
          @choices = {}
          @done = false
        end

        private

        def handle_event(event)
          if event.data.strip == DONE
            @done = true
            return
          end

          chunk = parse_json(event.data)
          return unless chunk.is_a?(Hash)

          if chunk["error"]
            error = chunk["error"]
            message = error.is_a?(Hash) ? [error["code"] || error["type"], error["message"]].compact.join(": ") : error.to_s
            raise_error_event!(message)
          end

          chunk.each do |key, value|
            next if value.nil?

            if key == "choices"
              value.each_with_index { |choice, position| merge_choice(choice, position) if choice.is_a?(Hash) }
            else
              @response[key] = value
            end
          end
        end

        def merge_choice(choice, position)
          index = choice["index"] || position
          merged = @choices[index] ||= {"index" => index, "message" => {"role" => "assistant", "content" => nil}, "tool_calls" => {}}

          merge_delta(merged, choice["delta"]) if choice["delta"].is_a?(Hash)
          merge_logprobs(merged, choice["logprobs"]) if choice["logprobs"].is_a?(Hash)
          merged["finish_reason"] = choice["finish_reason"] if choice["finish_reason"]
        end

        def merge_delta(merged, delta)
          message = merged["message"]
          delta.each do |key, value|
            next if value.nil?

            case key
            when "role"
              message["role"] = value
            when "tool_calls"
              value.each_with_index { |call, position| merge_tool_call(merged["tool_calls"], call, position) if call.is_a?(Hash) }
            when "annotations"
              (message["annotations"] ||= []).concat(value) if value.is_a?(Array)
            else
              if value.is_a?(String)
                message[key] = message[key] ? +message[key] : +""
                message[key] << value
              else
                message[key] = value
              end
            end
          end
        end

        def merge_tool_call(tool_calls, delta, position)
          call = tool_calls[delta["index"] || position] ||= {"function" => {}}
          call["id"] = delta["id"] if delta["id"]
          call["type"] = delta["type"] if delta["type"]

          function = delta["function"]
          return unless function.is_a?(Hash)

          call["function"]["name"] = function["name"] if function["name"]
          if function["arguments"]
            arguments = call["function"]["arguments"]
            call["function"]["arguments"] = arguments ? +arguments : +""
            call["function"]["arguments"] << function["arguments"]
          end
        end

        def merge_logprobs(merged, logprobs)
          target = merged["logprobs"] ||= {}
          logprobs.each do |key, value|
            if value.is_a?(Array)
              (target[key] ||= []).concat(value)
            elsif !value.nil?
              target[key] = value
            end
          end
        end

        def build_result
          incomplete!("Chat Completions stream ended without data: [DONE]") unless @done

          choices = @choices.sort_by { |index, _| index.to_i }.map { |_, choice| build_choice(choice) }
          @response.merge("object" => "chat.completion", "choices" => choices)
        end

        def build_choice(choice)
          message = choice["message"]
          tool_calls = choice["tool_calls"].sort_by { |index, _| index.to_i }.map do |_, call|
            {"type" => "function"}.merge(call)
          end
          message = message.merge("tool_calls" => tool_calls) unless tool_calls.empty?

          {
            "index" => choice["index"],
            "message" => message,
            "logprobs" => choice["logprobs"],
            "finish_reason" => choice["finish_reason"]
          }
        end
      end
    end
  end
end
