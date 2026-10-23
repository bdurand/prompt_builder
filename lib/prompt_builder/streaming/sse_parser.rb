# frozen_string_literal: true

module PromptBuilder
  module Streaming
    # Incremental parser for a Server-Sent Events (text/event-stream) body.
    #
    # Chunks can split the body anywhere, including in the middle of a line, a
    # CRLF pair, or a multi-byte UTF-8 character; only the current incomplete
    # line and the current event's fields are kept between calls. Lines may end
    # with LF, CRLF, or CR. Comment lines (starting with +:+) and unknown fields
    # are ignored, multiple +data+ lines are joined with newlines, and a leading
    # byte order mark is skipped. Unlike a browser EventSource, a final event
    # that is not followed by a blank line is still dispatched by #finish, since
    # some servers close the stream right after the last event.
    class SSEParser
      # A dispatched event.
      #
      # @!attribute [r] event
      #   @return [String, nil] the +event+ field, or nil when the event has none
      #     or an empty one (both mean the default +message+ event type)
      # @!attribute [r] data
      #   @return [String] the +data+ lines joined with newlines (UTF-8)
      # @!attribute [r] id
      #   @return [String, nil] the most recent +id+ field seen in the stream
      Event = Struct.new(:event, :data, :id)

      BOM = "\xEF\xBB\xBF".b.freeze
      private_constant :BOM

      LINE_BREAK = /[\r\n]/n
      private_constant :LINE_BREAK

      CR = 13
      private_constant :CR

      LF = 10
      private_constant :LF

      def initialize
        @buffer = +"".b
        # Where to resume searching for a line break, so an incomplete line
        # held across chunks is not rescanned from the start on every chunk.
        @scan_from = 0
        @bom_checked = false
        @event_type = nil
        @data_lines = []
        @last_event_id = nil
      end

      # Parse a chunk of the body, yielding each event it completes.
      #
      # @param chunk [String] the next chunk of the response body
      # @yieldparam event [Event] a completed event
      # @return [self]
      def feed(chunk, &block)
        @buffer << chunk.b
        return self unless skip_bom

        events = []
        pos = 0
        while (index = @buffer.index(LINE_BREAK, [pos, @scan_from].max))
          next_pos = index + 1
          if @buffer.getbyte(index) == CR
            # A CR at the end of the buffer may be the first half of a CRLF
            # split across chunks; wait for the next chunk to decide.
            break if next_pos == @buffer.bytesize
            next_pos += 1 if @buffer.getbyte(next_pos) == LF
          end
          process_line(@buffer.byteslice(pos, index - pos), events)
          pos = next_pos
        end
        @buffer = @buffer.byteslice(pos, @buffer.bytesize - pos) if pos > 0
        # The rest of the buffer has no line break, except possibly a trailing
        # CR, so the next search only needs to start at the last byte.
        @scan_from = [@buffer.bytesize - 1, 0].max

        events.each(&block)
        self
      end

      # Signal the end of the body, yielding the final event if it was not
      # followed by a blank line.
      #
      # @yieldparam event [Event] the final event
      # @return [self]
      def finish(&block)
        @bom_checked = true
        events = []
        unless @buffer.empty?
          line = @buffer.end_with?("\r") ? @buffer.byteslice(0, @buffer.bytesize - 1) : @buffer
          process_line(line, events)
          @buffer = +"".b
          @scan_from = 0
        end
        dispatch(events)

        events.each(&block)
        self
      end

      private

      # Strip a byte order mark from the start of the stream. Returns false
      # while the buffer is too short to tell whether it starts with one.
      def skip_bom
        return true if @bom_checked

        if @buffer.bytesize < BOM.bytesize && BOM.start_with?(@buffer)
          return false
        end

        @buffer = @buffer.byteslice(BOM.bytesize, @buffer.bytesize) if @buffer.start_with?(BOM)
        @bom_checked = true
      end

      def process_line(line, events)
        if line.empty?
          dispatch(events)
          return
        end
        return if line.start_with?(":")

        field, value = line.split(":", 2)
        value = value.to_s
        value = value.byteslice(1, value.bytesize) if value.start_with?(" ")

        case field
        when "event"
          # An empty event field means the default "message" type, the same
          # as no event field at all.
          @event_type = value.empty? ? nil : utf8(value)
        when "data"
          @data_lines << value
        when "id"
          @last_event_id = utf8(value) unless value.include?("\0")
        end
      end

      def dispatch(events)
        unless @data_lines.empty?
          events << Event.new(@event_type, utf8(@data_lines.join("\n")), @last_event_id)
        end
        @event_type = nil
        @data_lines = []
      end

      def utf8(value)
        value.dup.force_encoding(Encoding::UTF_8)
      end
    end
  end
end
