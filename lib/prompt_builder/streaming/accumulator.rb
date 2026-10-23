# frozen_string_literal: true

require "json"

module PromptBuilder
  module Streaming
    # Base class for the per-format accumulators that reassemble a streamed
    # response body into the Hash the non-streaming endpoint would have
    # returned, so it can be parsed with +Response.parse+.
    #
    # Feed the raw body in chunks of any size with #feed (or #<<), then call
    # #result. Only reassembly state is kept, not the raw body.
    #
    # A body that starts with +{+ or +[+ is not a stream (e.g. a JSON error
    # envelope returned with a 4xx status, or a server that ignored the stream
    # flag); it is buffered and returned parsed from #result, so +Response.parse+
    # handles it as it would a non-streamed body.
    #
    # Once #feed or #result raises, the accumulator is spent: later calls raise
    # the same error.
    #
    # Subclasses implement the private hooks +handle_event+ and +build_result+,
    # and may override +new_decoder+ (an SSEParser by default) and
    # +collapse_json+.
    #
    # @example
    #   accumulator = PromptBuilder::Serializers::Messages.stream_accumulator
    #   http_response.read_body { |chunk| accumulator << chunk }
    #   PromptBuilder::Response.parse(accumulator.result, :messages)
    class Accumulator
      JSON_START = /[^\t\n\r ]/n
      private_constant :JSON_START

      def initialize
        @leading = +"".b
        @mode = nil
        @decoder = nil
        @json_body = nil
        @finished = false
        @result = nil
        @error = nil
      end

      # Add the next chunk of the raw response body.
      #
      # @param chunk [String] the next chunk; may split events, lines, UTF-8
      #   characters, or binary frames anywhere
      # @return [self]
      # @raise [ErrorResponseError] if the stream contains an error event
      # @raise [ParseError] if the stream is malformed
      # @raise [InvalidStateError] if called after #result
      def feed(chunk)
        raise @error if @error
        raise InvalidStateError, "cannot feed a stream accumulator after calling result" if @finished
        return self if chunk.nil? || chunk.empty?

        capture_error do
          chunk = chunk.b
          case @mode
          when :stream then decode(chunk)
          when :json then @json_body << chunk
          else detect_mode(chunk)
          end
        end
        self
      end
      alias_method :<<, :feed

      # Finish the stream and return the reassembled response. The result is
      # computed once; later calls return the same Hash.
      #
      # @return [Hash, Array] the response the non-streaming endpoint would have
      #   returned (or the parsed body if it was not a stream)
      # @raise [IncompleteStreamError] if the stream ended before the format's
      #   terminal event
      # @raise [ErrorResponseError] if the stream contains an error event
      # @raise [ParseError] if the stream is malformed
      def result
        raise @error if @error
        return @result if @finished

        @finished = true
        capture_error { @result = finish_stream }
      end

      private

      # Create the decoder for the stream framing. It must respond to
      # +feed(chunk) { |event| }+ and +finish { |event| }+.
      def new_decoder
        SSEParser.new
      end

      # Process one decoded event (an SSEParser::Event or an
      # EventStreamDecoder::Message).
      def handle_event(_event)
        raise NotImplementedError
      end

      # Build the non-streaming response Hash once the stream has ended.
      def build_result
        raise NotImplementedError
      end

      # Convert a body that was not a stream into the result.
      def collapse_json(value)
        value
      end

      # Parse a JSON event payload.
      def parse_json(data)
        JSON.parse(data.dup.force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError => e
        raise ParseError, "streamed event is not valid JSON (#{e.message}): #{data.to_s[0, 200]}"
      end

      def raise_error_event!(message)
        message = "unknown error" if message.nil? || message.empty?
        raise ErrorResponseError, "the API returned an error: #{message}"
      end

      def incomplete!(message)
        raise IncompleteStreamError, message
      end

      # Decide from the first non-whitespace byte whether the body is a stream
      # or a plain JSON document. Leading whitespace is held until then.
      def detect_mode(chunk)
        @leading << chunk
        index = @leading.index(JSON_START)
        return unless index

        body = @leading
        @leading = nil
        if body.getbyte(index) == 0x7B || body.getbyte(index) == 0x5B # "{" or "["
          @mode = :json
          @json_body = body
        else
          @mode = :stream
          @decoder = new_decoder
          decode(body)
        end
      end

      def decode(chunk)
        @decoder.feed(chunk) { |event| handle_event(event) }
      end

      def finish_stream
        case @mode
        when :stream
          @decoder.finish { |event| handle_event(event) }
          build_result
        when :json
          collapse_json(parse_json(@json_body))
        else
          incomplete!("the streamed response body was empty")
        end
      end

      def capture_error
        yield
      rescue => e
        @error = e
        raise
      end
    end
  end
end
