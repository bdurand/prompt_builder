# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- `Session#think` can be called with no depth control (`session.think`), leaving whether and how much to reason to the target API's defaults. The Messages serializer maps it to adaptive thinking; other serializers send no depth control. Previously it raised an `ArgumentError`.
- `Session#think` accepts any `effort` level instead of raising an `ArgumentError` for levels outside `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`, since providers add new levels with new models (e.g. OpenAI's `none`). The level is forwarded to the API, which rejects levels the model doesn't support.
- The Messages serializer supports `reasoning.type: "between_tools"`, the lowest thinking setting on models that offer it. It was previously dropped silently, which sent the request with thinking left to the model — the opposite of what the caller asked for. It cannot be combined with `budget_tokens` or `display`.
- The Converse serializer maps `session.reasoning` (including `Session#think`) into `additionalModelRequestFields` for Anthropic and OpenAI models, which read their native reasoning fields from it: the Messages API `thinking` and `output_config.effort` for Anthropic models, and the `reasoning` object for OpenAI models. The model family is detected from the model id, allowing cross-region inference prefixes and ARNs. Values are forwarded without validation, and the fields are deep-merged into the `additional_model_request_fields` extra, whose values win on conflicts.

### Changed

- The Converse serializer raises an `UnsupportedFormatError` when `session.reasoning` is set for a model other than an Anthropic or OpenAI model, instead of warning and omitting it. Set the model's native reasoning fields through the `additional_model_request_fields` extra instead.
- The Messages serializer now emits a `thinking` parameter for any reasoning configuration that asks for thinking, where it previously only emitted one for `budget_tokens` or an explicit `reasoning.type`. Omitting `thinking` leaves the thinking mode to the model rather than turning thinking on, so `think(effort:)` produced no thinking on models that don't think by default. `thinking.type` defaults to `enabled` when `budget_tokens` is set, so `think(budget_tokens:)` serializes as before, and to `adaptive` for an `effort` level, `display`, or bare `think`. Adaptive thinking is not inferred from `effort` alongside `temperature`, a `top_p` below 0.95, or a forced `tool_choice`, so those sessions still send the effort on its own. Configurations without thinking keys (e.g. only another provider's `summary`) still emit no `thinking`.
- The Messages serializer forwards any `reasoning.type` to `thinking.type` instead of silently omitting the `thinking` parameter for types outside a fixed list, for the same reason. Which types a model accepts varies by model and changes often, so the API is left to reject types the model doesn't support.
- The Messages and Gemini serializers forward every `reasoning.effort` level to the API as is (Gemini upcases it) instead of dropping levels outside a fixed list. Which levels a model accepts varies by model and changes often, so the API is left to reject levels the model doesn't support. Previously, levels such as `minimal` on Messages or `xhigh` and `max` on Gemini were dropped silently, leaving the depth at the model's default.
- The Gemini serializer raises when `reasoning.budget_tokens` and `reasoning.effort` are both set, since the Gemini API rejects `thinkingBudget` and `thinkingLevel` in the same request.

### Removed

- `PromptBuilder::Serializers::Converse::Request.reset_reasoning_warning!`, since the Converse serializer no longer warns about reasoning.

### Fixed

- The Open Responses serializer no longer forwards the `budget_tokens`, `type`, and `display` reasoning keys, which are not part of the Open Responses schema and are rejected by the API. `think(budget_tokens:)` previously produced a payload the API rejects.

## 0.4.0

### Added

- `Response.parse` (and the serializer `parse_response` methods) accept an optional `headers:` keyword with the HTTP response headers, for formats that return response metadata in headers rather than in the body. The Converse serializer uses it to populate `Response#id` from the `x-amzn-requestid` request metadata header, since the Converse API does not include a response id in the body. The header name lookup is case-insensitive.

## 0.3.0

### Added

- Response parsers now recognize API error payloads (OpenAI/Gemini `error` envelopes, Anthropic `type: "error"` responses, Bedrock exception bodies) and raise a `PromptBuilder::ErrorResponseError` (a subclass of `UnexpectedPayloadError`) containing the error message reported by the API.
- `Session.new` accepts a `system:` shorthand that adds a system message, mirroring the existing `input:` shorthand.
- `Session#clear` resets the conversation — items, `instructions`, and `previous_response_id` — while preserving model configuration and registered tools.
- `Session#remove_tool` removes a registered tool by name (string or symbol); `Session#clear_tools` removes them all. Both return the removed definitions.
- `Session#extra=` sets or clears provider-specific extra data after the session has been constructed. Keys are normalized to strings; assigning `nil` clears the data.
- Message content hashes with a `text` key no longer require a `type` key; the type defaults to `input_text` (or `output_text` on assistant messages).
- `Items::Message#system?`, `#user?`, and `#assistant?` role predicates.
- The Converse serializer emits `cachePoint` markers from the `cache_point` extra on tool definitions and `FunctionCallOutput` items, in addition to content blocks.
- `Session#to_h`/`Session.from_h` now round-trip the response boundary (`response_boundary_index`), and a `response_boundary_index=` setter is available for reconstructing session state.
- `Session::INITIALIZE_OPTIONS` is now public API: the frozen Array of all keyword options accepted by the constructor, for code that needs to validate or partition an options hash before creating a session.

### Changed

- `Session#extra` always returns a Hash (previously `nil` when unset). The returned Hash is a copy; assign a modified copy back through `Session#extra=` to change it.
- `Session#to_h` omits `extra` when it is empty.
- `instructions` is now serialized after system/developer messages instead of before them, matching the Open Responses semantics of `instructions` applying to the current request.

### Fixed

- Serializers silently dropped `Content::Text` content (hashes with `type: "text"`) from messages, system prompts, and tool results; it is now serialized as text everywhere `InputText`/`OutputText` are, including cache markers from content extras. The Messages and Gemini serializers also dropped `OutputText` content from system messages.
- Tool names are normalized to strings on registration, so registering the same tool by symbol and by string no longer creates duplicate definitions.

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
