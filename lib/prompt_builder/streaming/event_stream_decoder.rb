# frozen_string_literal: true

require "zlib"

module PromptBuilder
  module Streaming
    # Incremental decoder for the AWS event-stream binary framing
    # (+application/vnd.amazon.eventstream+) used by Bedrock streaming APIs.
    #
    # Each message is a 12-byte prelude (total length, headers length, and a
    # CRC32 of those 8 bytes), the typed headers, the payload, and a CRC32 of
    # everything before it. Both checksums are verified. Chunks can split
    # messages anywhere; only the bytes of the current incomplete message are
    # kept between calls.
    class EventStreamDecoder
      # A decoded message.
      #
      # @!attribute [r] headers
      #   @return [Hash{String => Object}] the message headers (e.g.
      #     +":message-type"+, +":event-type"+, +":exception-type"+,
      #     +":content-type"+) keyed by name
      # @!attribute [r] payload
      #   @return [String] the raw payload bytes (binary encoding)
      Message = Struct.new(:headers, :payload)

      PRELUDE_LENGTH = 12
      private_constant :PRELUDE_LENGTH

      CRC_LENGTH = 4
      private_constant :CRC_LENGTH

      def initialize
        @buffer = +"".b
      end

      # Decode a chunk of the body, yielding each message it completes.
      #
      # @param chunk [String] the next chunk of the response body
      # @yieldparam message [Message] a decoded message
      # @return [self]
      # @raise [ParseError] if a checksum does not match or a message is malformed
      def feed(chunk, &block)
        @buffer << chunk.b

        messages = []
        pos = 0
        while @buffer.bytesize - pos >= PRELUDE_LENGTH
          total_length, headers_length = read_prelude(pos)
          break if @buffer.bytesize - pos < total_length

          messages << decode_message(@buffer.byteslice(pos, total_length), headers_length)
          pos += total_length
        end
        @buffer = @buffer.byteslice(pos, @buffer.bytesize - pos) if pos > 0

        messages.each(&block)
        self
      end

      # Signal the end of the body.
      #
      # @return [self]
      # @raise [IncompleteStreamError] if the body ended in the middle of a message
      def finish
        unless @buffer.empty?
          raise IncompleteStreamError,
            "event stream ended in the middle of a message (#{@buffer.bytesize} bytes left over)"
        end
        self
      end

      private

      def read_prelude(pos)
        total_length, headers_length, prelude_crc = @buffer.byteslice(pos, PRELUDE_LENGTH).unpack("NNN")
        actual_crc = Zlib.crc32(@buffer.byteslice(pos, 8))
        unless actual_crc == prelude_crc
          raise ParseError, "event stream prelude checksum mismatch (expected #{prelude_crc}, got #{actual_crc})"
        end
        if total_length < PRELUDE_LENGTH + CRC_LENGTH + headers_length
          raise ParseError, "event stream message length #{total_length} is too short for #{headers_length} bytes of headers"
        end

        [total_length, headers_length]
      end

      def decode_message(bytes, headers_length)
        expected_crc = bytes.byteslice(-CRC_LENGTH, CRC_LENGTH).unpack1("N")
        actual_crc = Zlib.crc32(bytes.byteslice(0, bytes.bytesize - CRC_LENGTH))
        unless actual_crc == expected_crc
          raise ParseError, "event stream message checksum mismatch (expected #{expected_crc}, got #{actual_crc})"
        end

        payload_length = bytes.bytesize - PRELUDE_LENGTH - headers_length - CRC_LENGTH
        Message.new(
          decode_headers(bytes.byteslice(PRELUDE_LENGTH, headers_length)),
          bytes.byteslice(PRELUDE_LENGTH + headers_length, payload_length)
        )
      end

      def decode_headers(bytes)
        headers = {}
        pos = 0
        take = lambda do |length|
          raise ParseError, "event stream message headers are truncated" if pos + length > bytes.bytesize

          value = bytes.byteslice(pos, length)
          pos += length
          value
        end

        while pos < bytes.bytesize
          name = take.call(take.call(1).unpack1("C")).force_encoding(Encoding::UTF_8)
          headers[name] = decode_header_value(take.call(1).unpack1("C"), take)
        end
        headers
      end

      def decode_header_value(type, take)
        case type
        when 0 then true
        when 1 then false
        when 2 then take.call(1).unpack1("c")
        when 3 then take.call(2).unpack1("s>")
        when 4 then take.call(4).unpack1("l>")
        when 5 then take.call(8).unpack1("q>")
        when 6 then take.call(take.call(2).unpack1("n"))
        when 7 then take.call(take.call(2).unpack1("n")).force_encoding(Encoding::UTF_8)
        when 8 then Time.at(0, take.call(8).unpack1("q>"), :millisecond).utc
        when 9 then take.call(16).unpack1("H*").sub(/\A(.{8})(.{4})(.{4})(.{4})/, '\1-\2-\3-\4-')
        else
          raise ParseError, "unknown event stream header value type #{type}"
        end
      end
    end
  end
end
