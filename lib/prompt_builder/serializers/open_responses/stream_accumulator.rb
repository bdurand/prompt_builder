# frozen_string_literal: true

module PromptBuilder
  module Serializers
    class OpenResponses < Base
      # Reassembles an Open Responses SSE stream into the response object the
      # non-streaming endpoint would have returned.
      #
      # The terminal events +response.completed+, +response.incomplete+, and
      # +response.failed+ each carry the full response object, so the result is
      # taken from that event rather than rebuilt from the deltas, and the
      # other events are ignored. An +error+ event raises an
      # ErrorResponseError.
      class StreamAccumulator < Streaming::Accumulator
        TERMINAL_EVENTS = %w[response.completed response.incomplete response.failed].freeze
        private_constant :TERMINAL_EVENTS

        def initialize
          super
          @response = nil
        end

        private

        def handle_event(event)
          type = event.event
          # Only the terminal and error events need parsing. Events without a
          # specific SSE event name are parsed to read the type from the data.
          return unless type.nil? || type == "message" || type == "error" || TERMINAL_EVENTS.include?(type)

          data = parse_json(event.data)
          return unless data.is_a?(Hash)

          type = data["type"] || type
          if TERMINAL_EVENTS.include?(type)
            @response = data["response"]
          elsif type == "error"
            # The error fields are either on the event itself or nested under
            # an "error" object.
            error = data["error"].is_a?(Hash) ? data["error"] : data.except("type")
            raise_error_event!([error["code"] || error["type"], error["message"]].compact.join(": "))
          end
        end

        def build_result
          unless @response.is_a?(Hash)
            incomplete!("Open Responses stream ended without a response.completed, response.incomplete, or response.failed event")
          end

          @response
        end
      end
    end
  end
end
