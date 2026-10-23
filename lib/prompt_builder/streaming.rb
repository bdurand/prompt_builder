# frozen_string_literal: true

module PromptBuilder
  # Building blocks for reassembling streamed API responses into the body the
  # non-streaming endpoint would have returned. Each serializer defines a
  # +StreamAccumulator+ subclass of Streaming::Accumulator for its format;
  # use +Serializers::Base.stream_accumulator+, +Serializers::Base.collapse_stream+,
  # or +Response.parse_stream+ rather than these classes directly.
  module Streaming
    autoload :Accumulator, File.expand_path("streaming/accumulator", __dir__)
    autoload :EventStreamDecoder, File.expand_path("streaming/event_stream_decoder", __dir__)
    autoload :SSEParser, File.expand_path("streaming/sse_parser", __dir__)
  end
end
