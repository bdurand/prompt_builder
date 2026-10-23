# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class Messages < Base
      # Reassembles an Anthropic Messages SSE stream into the message object
      # the non-streaming endpoint would have returned.
      #
      # +message_start+ provides the base message. Content blocks are tracked
      # by index: +text_delta+ and +citations_delta+ build text blocks,
      # +thinking_delta+ and +signature_delta+ build thinking blocks, and
      # +input_json_delta+ fragments are joined and parsed as the block's
      # +input+ when it stops. Blocks that arrive whole in
      # +content_block_start+ (e.g. +redacted_thinking+ and server tool
      # results) are kept as is. +message_delta+ provides the stop reason and
      # cumulative usage, which is merged into the +message_start+ usage.
      #
      # The stream must end with +message_stop+; an +error+ event raises an
      # ErrorResponseError. +ping+ and unknown events are ignored.
      class StreamAccumulator < Streaming::Accumulator
        def initialize
          super
          @message = {}
          @started = false
          @blocks = {}
          @input_json = {}
          @stopped = false
        end

        private

        def handle_event(event)
          data = parse_json(event.data)
          return unless data.is_a?(Hash)

          case data["type"] || event.event
          when "message_start"
            @message = data["message"] || {}
            @started = true
          when "content_block_start"
            @blocks[data["index"]] = data["content_block"] || {}
          when "content_block_delta"
            apply_delta(data["index"], data["delta"] || {})
          when "content_block_stop"
            finish_block(data["index"])
          when "message_delta"
            apply_message_delta(data)
          when "message_stop"
            @stopped = true
          when "error"
            error = data["error"].is_a?(Hash) ? data["error"] : {}
            raise_error_event!([error["type"], error["message"]].compact.join(": "))
          end
        end

        def apply_delta(index, delta)
          case delta["type"]
          when "text_delta"
            block = @blocks[index] ||= {"type" => "text"}
            append(block, "text", delta["text"])
          when "citations_delta"
            block = @blocks[index] ||= {"type" => "text"}
            (block["citations"] ||= []) << delta["citation"]
          when "thinking_delta"
            block = @blocks[index] ||= {"type" => "thinking"}
            append(block, "thinking", delta["thinking"])
          when "signature_delta"
            block = @blocks[index] ||= {"type" => "thinking"}
            append(block, "signature", delta["signature"])
          when "input_json_delta"
            (@input_json[index] ||= +"") << delta["partial_json"].to_s
          end
        end

        def append(block, key, value)
          block[key] = block[key] ? +block[key] : +""
          block[key] << value.to_s
        end

        def finish_block(index)
          json = @input_json.delete(index)
          return unless json

          block = @blocks[index] ||= {}
          block["input"] = json.empty? ? {} : parse_json(json)
        end

        def apply_message_delta(data)
          (data["delta"] || {}).each { |key, value| @message[key] = value }

          usage = data["usage"]
          return unless usage.is_a?(Hash)

          merged = (@message["usage"] || {}).dup
          usage.each { |key, value| merged[key] = value unless value.nil? }
          @message["usage"] = merged
        end

        def build_result
          incomplete!("Messages stream ended without a message_stop event") unless @stopped
          incomplete!("Messages stream ended without a message_start event") unless @started

          @input_json.keys.each { |index| finish_block(index) }
          content = @blocks.sort_by { |index, _| index.to_i }.map { |_, block| block }
          @message.merge("content" => content)
        end
      end
    end
  end
end
