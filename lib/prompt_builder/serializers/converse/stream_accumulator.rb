# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class Converse < Base
      # Reassembles a Bedrock +ConverseStream+ response (AWS event-stream
      # binary frames) into the +ConverseResponse+ the non-streaming +Converse+
      # endpoint would have returned: +output.message+, +stopReason+, +usage+,
      # and +metrics+.
      #
      # +messageStart+ provides the role. Content blocks are tracked by
      # +contentBlockIndex+: +contentBlockStart+ provides a tool use block's
      # +toolUseId+ and +name+, and +contentBlockDelta+ carries +text+,
      # +toolUse.input+ string fragments (joined and parsed as JSON when the
      # block stops), and +reasoningContent+ text, signature, and redacted
      # content. +messageStop+ provides +stopReason+ and
      # +additionalModelResponseFields+, and +metadata+ provides +usage+,
      # +metrics+, and any other response fields (e.g. +trace+).
      #
      # The stream must contain +messageStop+. Messages whose +:message-type+
      # is +exception+ or +error+ raise an ErrorResponseError. Unknown events
      # and delta types are ignored.
      #
      # The response id is not part of the stream; pass the HTTP headers to
      # +Response.parse+ (or +Response.parse_stream+) to populate it.
      class StreamAccumulator < Streaming::Accumulator
        # Bedrock adds a random-length "p" field to event payloads to mask
        # their size; it is not part of the response.
        PADDING_KEY = "p"
        private_constant :PADDING_KEY

        def initialize
          super
          @role = nil
          @blocks = {}
          @tool_inputs = {}
          @redacted = {}
          @stop = nil
          @metadata = nil
        end

        private

        def new_decoder
          Streaming::EventStreamDecoder.new
        end

        def handle_event(message)
          headers = message.headers
          case headers[":message-type"]
          when "event"
            data = parse_json(message.payload)
            handle_stream_event(headers[":event-type"], data) if data.is_a?(Hash)
          when "exception"
            raise_error_event!([headers[":exception-type"], exception_message(message.payload)].compact.join(": "))
          when "error"
            raise_error_event!([headers[":error-code"], headers[":error-message"]].compact.join(": "))
          end
        end

        def exception_message(payload)
          text = payload.dup.force_encoding(Encoding::UTF_8)
          data = JSON.parse(text)
          data.is_a?(Hash) ? (data["message"] || data["Message"]) : text
        rescue JSON::ParserError
          text.empty? ? nil : text
        end

        def handle_stream_event(type, data)
          case type
          when "messageStart"
            @role = data["role"]
          when "contentBlockStart"
            start_block(data["contentBlockIndex"], data["start"] || {})
          when "contentBlockDelta"
            apply_delta(data["contentBlockIndex"], data["delta"] || {})
          when "contentBlockStop"
            finish_block(data["contentBlockIndex"])
          when "messageStop"
            @stop = data.except(PADDING_KEY)
          when "metadata"
            @metadata = data.except(PADDING_KEY)
          end
        end

        def start_block(index, start)
          return unless start["toolUse"].is_a?(Hash)

          @blocks[index] = {"toolUse" => start["toolUse"].dup}
          @tool_inputs[index] = +""
        end

        def apply_delta(index, delta)
          if delta["text"]
            block = @blocks[index] ||= {}
            block["text"] = block["text"] ? +block["text"] : +""
            block["text"] << delta["text"]
          elsif delta["toolUse"].is_a?(Hash)
            @blocks[index] ||= {"toolUse" => {}}
            (@tool_inputs[index] ||= +"") << delta["toolUse"]["input"].to_s
          elsif delta["reasoningContent"].is_a?(Hash)
            apply_reasoning_delta(index, delta["reasoningContent"])
          end
        end

        def apply_reasoning_delta(index, delta)
          block = @blocks[index] ||= {}
          reasoning = block["reasoningContent"] ||= {}

          if delta["text"] || delta["signature"]
            text_block = reasoning["reasoningText"] ||= {"text" => +""}
            text_block["text"] << delta["text"] if delta["text"]
            if delta["signature"]
              text_block["signature"] = text_block["signature"] ? +text_block["signature"] : +""
              text_block["signature"] << delta["signature"]
            end
          end

          if delta["redactedContent"]
            # Blobs are base64 encoded per event, so decode each fragment and
            # re-encode the joined bytes when the result is built.
            (@redacted[index] ||= +"".b) << delta["redactedContent"].unpack1("m")
          end
        end

        def finish_block(index)
          json = @tool_inputs.delete(index)
          return unless json

          tool_use = (@blocks[index] ||= {})["toolUse"] ||= {}
          tool_use["input"] = json.empty? ? {} : parse_json(json)
        end

        def build_result
          incomplete!("Converse stream ended without a messageStop event") unless @stop

          @tool_inputs.keys.each { |index| finish_block(index) }
          @redacted.each do |index, bytes|
            @blocks[index]["reasoningContent"]["redactedContent"] = [bytes].pack("m0")
          end
          content = @blocks.sort_by { |index, _| index.to_i }.map { |_, block| block }

          result = {"output" => {"message" => {"role" => @role || "assistant", "content" => content}}}
          @stop.each { |key, value| result[key] = value unless value.nil? }
          @metadata&.each { |key, value| result[key] = value unless value.nil? }
          result
        end
      end
    end
  end
end
