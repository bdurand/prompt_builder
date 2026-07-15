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

  # Raised by Response#parsed_json! when the response text is not valid JSON.
  class ParseError < Error; end
end
