# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.3.0

### Added

- Response parsers now recognize API error payloads (e.g. OpenAI/Gemini `error` envelopes, Anthropic `type: "error"` responses, Bedrock exception bodies and Coral service envelopes) and raise a `PromptBuilder::ErrorResponseError` containing the error message reported by the API instead of a generic missing-key `UnexpectedPayloadError`.
- `PromptBuilder::ErrorResponseError` error class (a subclass of `UnexpectedPayloadError`).
- `Items::Message#system?`, `#user?`, and `#assistant?` role predicates.
- `Session#clear` removes all conversation items and the `instructions`, clears any `previous_response_id`, and returns the session to a fresh local-state start while preserving model configuration and registered tools.
- `Session#remove_tool` removes a single registered tool by name (string or symbol), returning the removed `Tools::Definition` or `nil` when not found.
- `Session#clear_tools` removes all registered tools from the session, returning the removed definitions.
- Message content hashes with a `text` key no longer require a `type` key: the type defaults to `input_text` (or `output_text` on assistant messages), so `session.system(text: "...", cache_point: true)` works without specifying a type.
- `Session#extra=` sets or clears provider-specific extra data after the session has been constructed, so options like the Converse `guardrail_config` no longer have to be passed to the constructor. Keys are normalized to strings on assignment, and assigning `nil` clears the data.

### Changed

- `Session#extra` now always returns a Hash, empty when nothing is set, instead of `nil`. The returned Hash is a copy, so mutating it does not affect the session; assign a modified copy back through `Session#extra=` instead.
- `Session#to_h` omits `extra` when it is empty. Previously `Session.new(extra: {})` emitted `"extra" => {}`.

- When a session has both `instructions` and system/developer messages, `instructions` is now serialized *after* the system/developer messages instead of before them (Chat Completions: inserted as a system message after the last system/developer message; Messages/Converse/Gemini: appended last in the merged top-level system field). This matches the Open Responses semantics of `instructions` applying to the current request, so it should follow system prompts accumulated in the conversation history.

### Fixed

- The Messages, Chat Completions, Converse, and Gemini serializers silently dropped `Content::Text` content (produced by content hashes with `type: "text"`) from system messages, user/assistant messages, and tool results. It is now serialized as text everywhere `InputText`/`OutputText` are, including the `cache_control` (Messages) and `cachePoint` (Converse) markers from content extras.

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
