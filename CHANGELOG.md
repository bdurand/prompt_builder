# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.2.0

### Added

- `Session#use_tools` copies tool definitions from a `ToolRegistry` (the global registry by default) onto the session by name, raising a `ToolNotFoundError` for unknown names.
- `Session#json_output` configures JSON Schema structured output without writing the raw `text.format` wire hash by hand.
- `Session#think` configures reasoning portably across serializers via `effort:` or `budget_tokens:`; `think(false)` clears the configuration.
- `Response#parsed_json` parses the response text as JSON (stripping fenced ```json wrappers), returning `nil` when it cannot be parsed; `Response#parsed_json!` raises a `ParseError` including the raw text instead.
- `Response.from_text` synthesizes a completed assistant text response for canned answers, cached responses, and tests.
- `PromptBuilder::ParseError` error class.

### Changed

- `Session.new` raises an `ArgumentError` when passed an unsupported keyword option instead of silently ignoring it.
- The Messages serializer raises an `UnsupportedFormatError` when `session.max_output_tokens` is not set, since the Messages API requires the `max_tokens` parameter.
- Serializers now raise an `UnsupportedFormatError` for missing fields their target API requires instead of emitting an invalid payload: Chat Completions, Converse, and Open Responses require `session.model`; Chat Completions requires at least one message; Gemini requires a non-empty `contents` array.
- The Messages serializer raises an `UnsupportedFormatError` when thinking is enabled with a `budget_tokens` that is not less than `max_output_tokens`, matching the Anthropic API requirement that `max_tokens` be greater than the thinking budget.
- The Converse serializer warns once per process when `session.reasoning` is set instead of silently dropping it (the Converse endpoint has no reasoning parameter).

## 0.1.2

### Fixed

- `Session#add_function_call_output` raised a `NameError`; it now correctly builds an `Items::FunctionCallOutput`.
- Provider-specific `extra` data on items, content blocks, and tool definitions (e.g. `cache_control`, `cache_point`, `thought_signature`, `media_type`) leaked into Open Responses request payloads and would be rejected as unknown parameters. It is now stripped from `request_payload(:open_responses)`.
- The Messages serializer emitted all `OutputText.annotations` as text-block `citations`, including annotation shapes from other providers (e.g. Chat Completions `url_citation`) that the Anthropic API rejects. Only valid Anthropic citation types are now emitted.
- The Chat Completions serializer emitted tool messages with an empty content array when a tool result contained no text content; it now collapses to an empty string.
- The Chat Completions response parser duplicated message-level `annotations` and `logprobs` onto every text block; they are now attached only to the first.
- `PromptBuilder.parse_data_url` now accepts data URLs with media type parameters (e.g. `data:text/plain;charset=utf-8;base64,...`).

### Added

- `Response#provider_data` as an alias for `Response#extra`.

## 0.1.1

### Changed

- Responses will now raise an `UnsupportedFormatError` if the response shape is missing key elements.
- Removed the default `max_tokens` value of 4096 from the request serializer. If `max_output_tokens` is not set on the session, the request will simply omit the `max_tokens` parameter, allowing the API to apply its own defaults.

## 0.1.0

### Added

- Initial release.
