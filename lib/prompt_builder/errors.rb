# frozen_string_literal: true

module PromptBuilder
  # Base error class for all PromptBuilder errors.
  class Error < StandardError; end

  # Raised when a format conversion is not supported.
  class UnsupportedFormatError < Error; end

  # Raised when an invalid item type is encountered.
  class InvalidItemError < Error; end

  # Raised when a tool is not found in the registry.
  class ToolNotFoundError < Error; end

  # Raised when an operation is invalid for the current session state.
  class InvalidStateError < Error; end

  # Raised when a response payload does not match the expected shape.
  class UnexpectedPayloadError < Error; end

  # Raised when a response payload is an error returned by the API rather
  # than a completion (e.g. an authentication, validation, or throttling
  # error envelope). The message contains the error reported by the API.
  class ErrorResponseError < UnexpectedPayloadError; end

  # Raised when a streamed response ends before the format's terminal event
  # (e.g. a dropped connection), so a truncated stream is never treated as a
  # complete response.
  class IncompleteStreamError < UnexpectedPayloadError; end

  # Raised when text or binary data cannot be decoded: by Response#parsed_json!
  # when the response text is not valid JSON, and by the stream decoders when a
  # streamed response body is malformed (e.g. an AWS event-stream checksum
  # mismatch or an unparseable event payload).
  class ParseError < Error; end
end
