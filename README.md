# PromptBuilder

[![Continuous Integration](https://github.com/bdurand/prompt_builder/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/prompt_builder/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/prompt_builder.svg)](https://badge.fury.io/rb/prompt_builder)

This gem provides a Ruby DSL for building and parsing LLM API request payloads. The goal of this gem is to provide a single, consistent interface for constructing requests and parsing responses across multiple LLM APIs without locking you into a specific provider or HTTP client. Chat sessions are designed to be serializable so they can be persisted into databases or caches.

The [Open Responses API](https://www.openresponses.org/) is used as the internal data model. The [Open Responses reference](https://www.openresponses.org/reference) documentation provides details on how to use the API and the terminology.

Requests can be generated for and responses can be parsed from these common LLM API formats:

- [Open Responses API](https://www.openresponses.org/)
- [OpenAI Chat Completions API](https://platform.openai.com/docs/api-reference/chat)
- [Anthropic Messages API](https://docs.anthropic.com/en/api/messages)
- [Google Gemini API](https://ai.google.dev/api/generate-content)
- [Amazon Bedrock Converse API](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html)

This gem does **not** include any HTTP client code. It is designed to be used with whatever HTTP library you prefer. You build a request payload, send it to the API yourself, and then parse the response back into Ruby objects.

It was specifically designed to work with the [patient_http](https://github.com/bdurand/patient_http) gem to allow making asynchronous requests to LLM APIs and is used in the [patient_llm](https://github.com/bdurand/patient_llm) gem.

## Usage

- [Sessions](#sessions)
- [Conversation History](#conversation-history)
- [Serializing Requests](#serializing-requests)
- [Parsing Responses](#parsing-responses)
- [Agentic Tool Loops](#agentic-tool-loops)
- [Tool Registry](#tool-registry)
- [Content Types](#content-types)
- [Configuration Options](#configuration-options)
- [Serialization and Persistence](#serialization-and-persistence)
- [Serializer Compatibility](#serializer-compatibility)

### Sessions

The `PromptBuilder::Session` class is the main entry point. A session holds the model configuration, conversation history, and tool definitions needed to build a request payload.

```ruby
session = PromptBuilder::Session.new(
  model: "gpt-5.4",
  instructions: "You are a helpful assistant.",
  temperature: 0.7
)

# Add a user message to the conversation history
session.user("What is the capital of France?")
```

You can also pass an `input` shorthand to create a user message in one step:

```ruby
session = PromptBuilder::Session.new(
  model: "gpt-5.4",
  input: "What is the capital of France?"
)
```

Passing an option the constructor doesn't recognize (or both halves of an alias pair) raises an `ArgumentError`.

### Conversation History

Build up a multi-turn conversation by adding messages:

```ruby
session = PromptBuilder::Session.new(model: "gpt-5.4")
session.system("You are a helpful assistant.")
session.user("Hello!")
session.assistant("Hi there! How can I help you today?")
session.user("What's the weather like?")
```

Messages support the roles `user`, `assistant`, `system`, and `developer`. A `Message` exposes `system?`, `user?`, and `assistant?` predicates for checking its role.

### Serializing Requests

Once you've built a session, serialize it to a request payload for the API you want to call. Five target formats are supported:

**Open Responses API**:

```ruby
payload = session.request_payload(:open_responses)
```

Note that `session.to_h` is *not* a request payload — it is the persistence format used by `Session.from_h` and keeps provider-specific `extra` data, canonical `url` content keys, and non-replayable items that the Open Responses API would reject. Always build request payloads through `request_payload`.

**OpenAI Chat Completions API**:

```ruby
payload = session.request_payload(:chat_completion)
```

**Anthropic Messages API**:

```ruby
payload = session.request_payload(:messages)
```

**Google Gemini API**:

```ruby
payload = session.request_payload(:gemini)
```

**Amazon Bedrock Converse API**:

```ruby
payload = session.request_payload(:converse)
```

The payload is a plain Ruby `Hash` that you can convert to JSON and send to the API with any HTTP client:

```ruby
require "net/http"
require "json"

uri = URI("https://api.openai.com/v1/responses")
request = Net::HTTP::Post.new(uri)
request["Authorization"] = "Bearer #{api_key}"
request["Content-Type"] = "application/json"
request.body = JSON.generate(session.request_payload(:open_responses))

response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
  http.request(request)
end
```

### Parsing Responses

Parse an API response back into an `PromptBuilder::Response` object using `Response.parse` with a serializer symbol:

```ruby
# Open Responses API
response = PromptBuilder::Response.parse(JSON.parse(response_body), :open_responses)

# OpenAI Chat Completions API
response = PromptBuilder::Response.parse(JSON.parse(response_body), :chat_completion)

# Anthropic Messages API
response = PromptBuilder::Response.parse(JSON.parse(response_body), :messages)

# Google Gemini API
response = PromptBuilder::Response.parse(JSON.parse(response_body), :gemini)

# Amazon Bedrock Converse API
response = PromptBuilder::Response.parse(JSON.parse(response_body), :converse)
```

You can also pass a serializer class directly:

```ruby
response = PromptBuilder::Response.parse(JSON.parse(response_body), PromptBuilder::Serializers::ChatCompletion)
```

The `Response` object provides convenient accessors:

```ruby
response.text            # => "The capital of France is Paris."
response.completed?      # => true
response.has_tool_calls? # => false
response.usage           # => #<PromptBuilder::Usage input_tokens=25 output_tokens=12 ...>
```

If the payload is an error returned by the API rather than a completion (e.g. an authentication failure, a validation error, or an AWS Coral service envelope), `Response.parse` raises a `PromptBuilder::ErrorResponseError` whose message contains the error reported by the API. Payloads that are neither a completion nor a recognizable error envelope raise a `PromptBuilder::UnexpectedPayloadError` (which `ErrorResponseError` subclasses) including the offending body.

```ruby
PromptBuilder::Response.parse({"error" => {"type" => "invalid_request_error", "message" => "Incorrect API key provided"}}, :chat_completion)
# => raises PromptBuilder::ErrorResponseError: the API returned an error: invalid_request_error: Incorrect API key provided
```

You can also synthesize a plain-text response without calling an API — useful for canned answers (e.g. halting an agent loop), cached responses, and tests:

```ruby
response = PromptBuilder::Response.from_text("Authentication failed.",
  model: llm_response.model, usage: llm_response.usage)
response.text        # => "Authentication failed."
response.completed?  # => true
```

### Structured Output

Use `json_output` to request JSON Schema structured output and `parsed_json` to read it back:

```ruby
schema = {
  "type" => "object",
  "properties" => {"answer" => {"type" => "string"}},
  "required" => ["answer"]
}

session.json_output(schema, name: "response", strict: true)
payload = session.request_payload(:messages)  # works with all five serializers

# After parsing the API response:
data = response.parsed_json    # => {"answer" => "..."} or nil if the text isn't valid JSON
data = response.parsed_json!   # raises PromptBuilder::ParseError (including the raw text) instead
```

`parsed_json` strips fenced ```` ```json ```` wrappers, a common provider quirk. `json_output` is sugar for setting `session.text` to the canonical `format` wire hash, so direct `session.text = {...}` assignment keeps working.

### Reasoning / Extended Thinking

Use `think` to configure reasoning portably; each serializer maps it to its native parameter:

```ruby
session.think(effort: :medium)       # portable across serializers
session.think(budget_tokens: 8_000)  # explicit token budget where supported
session.think(false)                 # clear the reasoning configuration
```

- `effort:` (one of `minimal`, `low`, `medium`, `high`, `xhigh`, `max`) maps to `output_config.effort` (Messages), `reasoning_effort` (Chat Completions), `thinkingConfig.thinkingLevel` (Gemini), and `reasoning.effort` (Open Responses). Levels a target API doesn't accept are omitted.
- `budget_tokens:` maps to `thinking.budget_tokens` (Messages) and `thinkingConfig.thinkingBudget` (Gemini); effort-based APIs ignore it. The Messages serializer raises an `UnsupportedFormatError` at `request_payload` time when `max_output_tokens` is not greater than the budget, since the Anthropic API requires `max_tokens > budget_tokens`.
- The Converse API has no reasoning parameter; the serializer warns once per process and omits the configuration.

Direct `session.reasoning = {...}` assignment keeps working for provider-specific keys (e.g. Anthropic's `display`, Gemini's `summary`).

### Agentic Tool Loops

You can register tool definitions on a session, add API responses to the conversation, and manually append tool outputs to build an agentic loop:

```ruby
session = PromptBuilder::Session.new(model: "gpt-5.4")

session.register_tool(
  "get_weather",
  description: "Get the current weather for a city.",
  parameters: {
    "type" => "object",
    "properties" => {
      "city" => {"type" => "string", "description" => "The city name"}
    },
    "required" => ["city"]
  }
)

session.user("What's the weather in Paris?")

loop do
  payload = session.request_payload(:chat_completion)
  response_body = call_api(payload)  # Your HTTP call
  response = PromptBuilder::Response.parse(response_body, :chat_completion)

  session.add_response(response)

  unless response.has_tool_calls?
    puts response.text
    break
  end

  # Invoke tool handlers for each tool call in this response and append the
  # output back to the session before the next iteration.
  response.tool_calls.each do |call|
    result = call_tool(call.name, call.parsed_arguments)  # invoke your logic for the tool
    session.add_function_call_output(call_id: call.call_id, result: result.to_s)
  end
end
```

The `add_response` method appends the model's output items (messages, tool calls, reasoning, etc.) to the session's conversation history. You add `FunctionCallOutput` items manually after invoking each tool, then loop until the model produces a final text response.

### Tool Registry

For tools that are shared across multiple sessions, you can use a `ToolRegistry`:

```ruby
registry = PromptBuilder::ToolRegistry.new

registry.register(
  "search",
  description: "Search the knowledge base.",
  parameters: {
    "type" => "object",
    "properties" => {
      "query" => {"type" => "string"}
    },
    "required" => ["query"]
  }
) do |args|
  KnowledgeBase.search(args["query"])
end

# Apply all tools from the registry to a session
session = PromptBuilder::Session.new(model: "gpt-5.4")
session.register_tools(registry)
```

There is also a global registry available on the `PromptBuilder` module:

```ruby
PromptBuilder.register_tool("search", description: "Search the knowledge base.") do |args|
  KnowledgeBase.search(args["query"])
end

session.register_tools(PromptBuilder.tool_registry)
```

Use `use_tools` to attach a subset of registry tools by name without copying schemas by hand. Unknown names raise a `ToolNotFoundError`, so a typo fails fast instead of producing a silently absent tool:

```ruby
session.use_tools("weather", "traffic_conditions")   # from PromptBuilder.tool_registry
session.use_tools                                     # all tools in the registry
session.use_tools(:weather, registry: my_registry)    # explicit registry
```

Tool definitions are *copied* onto the session in all cases, so later registry changes don't affect the session and the tools survive `to_h`/`from_h` round-trips.

### Content Types

Message content can be a plain string or an array of structured content objects for multi-modal input. Content can be provided as raw Hashes or as `PromptBuilder::Content` objects.

**Images**

Send an image by URL or as base64-encoded data:

```ruby
# Image from a URL
session.user([
  PromptBuilder::Content::InputText.new(text: "What is in this image?"),
  PromptBuilder::Content::InputImage.new(url: "https://example.com/photo.jpg")
])

# Image with a detail level hint
session.user([
  PromptBuilder::Content::InputText.new(text: "Describe this image in detail."),
  PromptBuilder::Content::InputImage.new(
    url: "https://example.com/photo.jpg",
    detail: "high"
  )
])

# Image from raw binary data using a data URL
session.user([
  PromptBuilder::Content::InputText.new(text: "What is in this image?"),
  PromptBuilder::Content::InputImage.new(
    url: PromptBuilder.data_url(File.binread("photo.png"), "image/png")
  )
])
```

**Files**

Attach a file by URL or as raw binary data:

```ruby
# File from a URL
session.user([
  PromptBuilder::Content::InputText.new(text: "Summarize this document."),
  PromptBuilder::Content::InputFile.new(url: "https://example.com/report.pdf")
])

# File from raw binary data with a filename and media type
session.user([
  PromptBuilder::Content::InputText.new(text: "What does this spreadsheet contain?"),
  PromptBuilder::Content::InputFile.new(
    url: PromptBuilder.data_url(File.binread("data.csv"), "text/csv"),
    filename: "data.csv"
  )
])

# Reference a previously uploaded file by id (OpenAI Files API, Gemini Files API)
session.user([
  PromptBuilder::Content::InputText.new(text: "Summarize this."),
  PromptBuilder::Content::InputFile.new(file_id: "file_abc123", media_type: "application/pdf")
])
```

**Videos**

```ruby
session.user([
  PromptBuilder::Content::InputText.new(text: "Summarize what happens in this video."),
  PromptBuilder::Content::InputVideo.new(url: "https://example.com/clip.mp4")
])
```

**Using Hashes**

You can also pass plain Hashes instead of content objects:

```ruby
session.user([
  {"type" => "input_text", "text" => "What is in this image?"},
  {"type" => "input_image", "url" => "https://example.com/photo.jpg"}
])
```

**Supported content types**

| Type | Class | Description |
|------|-------|-------------|
| `input_text` | `Content::InputText` | Text input |
| `input_image` | `Content::InputImage` | Image input (URL or base64) |
| `input_file` | `Content::InputFile` | File input (URL or base64) |
| `input_video` | `Content::InputVideo` | Video input (URL) |
| `output_text` | `Content::OutputText` | Text output from the model |
| `refusal` | `Content::RefusalContent` | Refusal content from the model |

### Configuration Options

Sessions support a wide range of configuration options that map to common API parameters:

```ruby
session = PromptBuilder::Session.new(
  model: "gpt-5.4",
  instructions: "You are a helpful assistant.",
  temperature: 0.7,
  top_p: 0.9,
  max_output_tokens: 1024,
  frequency_penalty: 0.5,
  presence_penalty: 0.5,
  parallel_tool_calls: true,
  reasoning: {"effort" => "high"},
  text: {"format" => {"type" => "json_object"}},
  tool_choice: "auto",
  truncation: "auto",
  prompt_cache_key: "account-123",
  prompt_cache_retention: "24h",
  store: true,
  metadata: {"user_id" => "123"}
)
```

### Provider-Specific Extra Parameters

The `extra` attribute on sessions, content blocks, and tool definitions lets you pass provider-specific parameters that are not part of the Open Responses canonical format. Each serializer recognizes a defined set of `extra` keys and maps them to the appropriate location in the target format. Unrecognized keys are silently ignored.

#### Session Extra

Pass provider-specific top-level request parameters via `session.extra`:

```ruby
# Anthropic Messages: top_k, stop_sequences, cache_control
session = PromptBuilder::Session.new(
  model: "claude-sonnet-4-20250514",
  extra: {
    "top_k" => 40,
    "stop_sequences" => ["\n\nHuman:"],
    "cache_control" => {"type" => "ephemeral"}
  }
)

# OpenAI Chat Completions: stop, seed, logit_bias, n, web_search_options
session = PromptBuilder::Session.new(
  model: "gpt-4o",
  extra: {
    "stop" => ["END", "\n\n"],
    "seed" => 42,
    "web_search_options" => {"search_context_size" => "medium"}
  }
)

# Google Gemini: safety_settings, cached_content, stop_sequences, top_k, seed
session = PromptBuilder::Session.new(
  model: "gemini-2.0-flash",
  extra: {
    "safety_settings" => [
      {"category" => "HARM_CATEGORY_HATE_SPEECH", "threshold" => "BLOCK_ONLY_HIGH"}
    ],
    "cached_content" => "cachedContents/abc123",
    "stop_sequences" => ["END"],
    "top_k" => 40,
    "seed" => 42
  }
)

# Amazon Bedrock Converse: stop_sequences, guardrail_config, additional_model_request_fields
session = PromptBuilder::Session.new(
  model: "anthropic.claude-v2",
  extra: {
    "stop_sequences" => ["\n\nHuman:"],
    "guardrail_config" => {
      "guardrailIdentifier" => "my-guardrail",
      "guardrailVersion" => "1"
    },
    "additional_model_request_fields" => {"top_k" => 50}
  }
)
```

#### Content Extra

Content blocks support provider-specific attributes via keyword arguments that are captured in the `extra` hash:

```ruby
# Anthropic Messages: cache_control on content blocks for prompt caching
session.system([
  PromptBuilder::Content::InputText.new(
    text: "You are an assistant with a large knowledge base...",
    cache_control: {"type" => "ephemeral"}
  )
])

# Anthropic Messages: citations opt-in on document blocks
session.user([
  PromptBuilder::Content::InputFile.new(
    url: "https://example.com/report.pdf",
    citations: {"enabled" => true}
  ),
  PromptBuilder::Content::InputText.new(text: "Summarize with citations.")
])

# Bedrock Converse: cache_point markers
session.user([
  PromptBuilder::Content::InputText.new(
    text: "Long context that should be cached...",
    cache_point: true
  )
])
```

#### Tool Definition Extra

Tool definitions accept provider-specific parameters as keyword arguments:

```ruby
# Anthropic Messages: cache_control on tool definitions
session.register_tool(
  "search",
  description: "Search the knowledge base.",
  parameters: {"type" => "object", "properties" => {"query" => {"type" => "string"}}},
  cache_control: {"type" => "ephemeral"}
)
```

#### Recognized Extra Keys by Serializer

| Serializer | Session Extra Keys | Content Extra Keys | Tool Extra Keys |
|:---|:---|:---|:---|
| **Chat Completions** | `stop`, `seed`, `logit_bias`, `n`, `prediction`, `web_search_options`, `modalities`, `audio` | `file_id`, `media_type` | — |
| **Messages** | `top_k`, `stop_sequences`, `cache_control` | `cache_control`, `citations`, `file_id`, `media_type` | `cache_control` |
| **Gemini** | `safety_settings`, `cached_content`, `stop_sequences`, `top_k`, `seed`, `candidate_count`, `response_modalities`, `media_resolution` | `file_id`, `media_type`, `thought_signature` | — |
| **Converse** | `stop_sequences`, `guardrail_config`, `additional_model_request_fields`, `additional_model_response_field_paths`, `performance_config`, `prompt_variables` | `media_type`, `cache_point` | — |

### Serialization and Persistence

Sessions and responses can be serialized to and from Hashes for storage or transmission:

```ruby
# Serialize a session to a Hash
hash = session.to_h

# Restore a session from a Hash
restored_session = PromptBuilder::Session.from_h(hash)
```

This makes it straightforward to persist conversation state in a database or cache between requests.

> [!WARNING]
> `to_h` is the persistence format, not a request payload. It retains provider-specific `extra` data and non-replayable items that APIs reject. Send the output of `request_payload(serializer)` to APIs, and use `to_h`/`from_h` only for storage.

## Serializer Compatibility

The Open Responses format is the canonical data model for this gem. When serializing to other formats, some features may not be available because either the target API does not support them or because the Open Responses format does not expose parameters unique to the target API. If you attempt to use a feature that is not supported by a particular serializer, it will be silently omitted from the serialized output.

### Session Fields

The following table shows which session configuration fields are supported by each serializer. ❌ means the field is silently omitted from the serialized output. Partial support is noted inline.

| Session Field | ChatCompletion | Messages | Gemini | Converse |
|:---|:---:|:---:|:---:|:---:|
| `background` | ❌ | ❌ | ❌ | ❌ |
| `frequency_penalty` | ✅ | ❌ | ✅ → `generationConfig.frequencyPenalty` | ❌ |
| `include` | ❌ | ❌ | ❌ | ❌ |
| `max_tool_calls` | ❌ | ❌ | ❌ | ❌ |
| `metadata` | ✅ | `user_id` key only | ❌ | ✅ → `requestMetadata`¹³ |
| `parallel_tool_calls` | ✅ | ✅ | ❌ | ❌ |
| `presence_penalty` | ✅ | ❌ | ✅ → `generationConfig.presencePenalty` | ❌ |
| `prompt_cache_key` | ✅ | ❌ | ❌ | ❌ |
| `prompt_cache_retention` | ✅ | ❌ | ❌ | ❌ |
| `reasoning` | `effort` key only | `budget_tokens`/`display`/`effort`/`type` only | `budget_tokens`/`effort`/`summary: "auto"` only | ❌ |
| `safety_identifier` | ✅ | ✅ → `metadata.user_id` | ❌ | ❌ |
| `service_tier` | ✅ | `auto`/`standard_only` only | `unspecified`/`standard`/`flex`/`priority` only | ✅ → `serviceTier.type` |
| `store` | ✅ | ❌ | ✅ | ❌ |
| `stream` | ✅ | ✅ | endpoint-selected⁸ | ❌ |
| `stream_options` | `include_usage`/`include_obfuscation` only | ❌ | ❌ | ❌ |
| `text` | `format`/`verbosity` only | `format.type=json_schema` only | `format` key only | `format.type == json_schema` only |
| `top_logprobs` | ✅ | ❌ | ✅ → `responseLogprobs`/`logprobs` | ❌ |
| `truncation` | ❌ | ❌ | ❌ | ❌ |

### Content Types

| Content Type | ChatCompletion | Messages | Gemini | Converse |
|:---|:---:|:---:|:---:|:---:|
| `InputText` | ✅ | ✅ | ✅ | ✅ |
| `InputImage` | user messages only⁷ | user messages only⁵ | user messages only⁶ | base64 or S3 URI only |
| `InputFile` | user messages only¹⁰ | user messages only¹ | user messages only⁶ | base64 or S3 URI only² |
| `InputVideo` | ❌ | ❌ | URL required (Google-hosted URI only)⁶ | S3 URI only |
| `OutputText` | ✅ (annotations dropped on request)¹¹ | ✅ (annotations ↔ citations)¹² | ✅ | ✅ |
| `RefusalContent` | dropped⁹ | dropped⁹ | dropped⁹ | dropped⁹ |
| `Reasoning` items | ❌ | ✅³ | ✅⁴ | ❌ |
| `Compaction` items | ❌ | ❌ | ❌ | ❌ |
| `ItemReference` items | ❌ | ❌ | ❌ | ❌ |

¹ Messages format uses the media type from the data URL for base64 sources; set `InputFile.media_type` to override. `file_id` is mapped to a `file` source for the Anthropic Files API beta — set the appropriate `anthropic-beta: files-api-2025-04-14` header in your HTTP client.
² Converse format infers the document type from the filename or URL extension.
³ Messages format only emits `thinking` blocks that include a cryptographic `signature`; unsigned blocks are silently dropped.
⁴ Gemini format passes `thoughtSignature` through transparently on reasoning, text, and function-call parts. `redacted_thinking` blocks are silently skipped.
⁵ Anthropic does not support a `detail` field on images; it is silently dropped. `file_id` is mapped to a `file` source (Anthropic Files API beta).
⁶ Gemini supports inline base64 data or any URL. For files, set `media_type` or use a recognized `filename`/URL extension.
⁷ Chat Completions does not accept `InputImage.file_id` — the `image_file` content type is Assistants API only. Use a URL or base64 `data` instead; a `file_id`-only image is omitted.
⁸ Gemini selects streaming by endpoint (`:streamGenerateContent`), not a request body field, so `session.stream` is silently ignored when serializing to Gemini.
⁹ `RefusalContent` blocks are dropped silently by all request serializers so a parsed refusal can sit in session history without breaking subsequent `request_payload` calls. A message left empty after stripping is omitted entirely.
¹⁰ Chat Completions sends `InputFile` as a `{"type": "file", "file": {...}}` content block. `file_id` (Files API) and base64 data URL (with optional `filename`/`media_type`) are supported. A URL-only `InputFile` (non-data URL) is omitted because Chat Completions has no remote-URL form for files.
¹¹ `OutputText.annotations` (e.g. URL citations from `web_search_options`) are parsed onto the assistant message and round-trip through session history, but are dropped silently on Chat Completions and Converse request serialization since those formats have no request-side equivalent. `OutputText.logprobs` is likewise dropped.
¹² Messages text-block `citations` are parsed into `OutputText.annotations` and emitted back as `citations` when serializing Messages history. Annotations from other providers (e.g. a Chat Completions `url_citation`) are silently dropped since they are not valid Anthropic citation shapes. Document/tool-result citation opt-ins are still not modeled.
¹³ Converse `requestMetadata` only accepts string key/value pairs. This serializer stringifies scalar metadata values and silently omits nested arrays or objects.

### Features Not Accessible Through Open Responses

These target API features are not available through the Open Responses canonical format because Open Responses does not expose the equivalent parameters:

| Feature | ChatCompletion | Messages | Gemini | Converse |
|:---|:---:|:---:|:---:|:---:|
| Audio input | ✅ | — | ✅ | — |
| Audio output / TTS | ✅ | — | ✅ | — |
| Output `modalities` selection | ✅ | — | ✅ | — |
| `top_k` sampling | — | ✅ | ✅ | — |
| `seed` | ✅ | — | ✅ | — |
| Stop sequences | ✅ | ✅ | ✅ | ✅ |
| Structured output JSON schema | ✅ | ✅ | ✅ | ✅ |
| Top-level `cache_control` | — | ✅ | — | — |
| `logit_bias` | ✅ | — | — | — |
| Multiple candidates (`n`) | ✅ | — | ✅ (request unsupported; parsing keeps only the first candidate) | — |
| Speculative decoding (`prediction`) | ✅ | — | — | — |
| `tool_choice` `allowed_tools` shape | ✅ | — | — | — |
| Custom (non-function) tool types | ✅ | — | — | — |
| Strict tool definitions | ✅ | ✅ | ✅ (`VALIDATED` exists, but per-tool `strict` is not supported by this gem) | — |
| Deprecated Chat `functions` / `function_call` / `max_tokens` / `user` fields | ✅ | — | — | — |
| Built-in web search (`web_search_options`) | ✅ | ✅ | ✅ | — |
| Configurable safety thresholds | — | — | ✅ | — |
| Guardrail policies (`guardrailConfig`, `guardContent`) | — | — | — | ✅ |
| Cross-region routing (inference profiles) | — | — | — | ✅ |
| Prompt caching (`cache_control` markers) | — | ✅ | — | — |
| Prompt caching (`cachePoint` blocks) | — | — | — | ✅ |
| Citations on documents and tool results | — | ✅ | — | ✅ |
| `additionalModelRequestFields` / `additionalModelResponseFieldPaths` | — | — | — | ✅ |
| Bedrock Prompt Management variables (`promptVariables`) | — | — | — | ✅ |
| `search_result` content blocks | — | ✅ | — | ✅ |
| Audio content blocks | ✅ | — | ✅ | ✅ |
| MCP connectors (`mcp_servers`) | — | ✅ | — | — |
| Code execution `container` reuse | — | ✅ | — | — |
| Geographic inference routing (`inference_geo`) | — | ✅ | — | — |
| Beta API headers (`anthropic-beta`, etc.) | — | ✅ | ✅ | — |
| Built-in code execution | — | ✅ | ✅ | — |
| Built-in computer use | — | ✅ | ✅ | — |
| Built-in bash / text editor / memory tools | — | ✅ | — | — |
| Built-in URL context retrieval (`urlContext`) | — | — | ✅ | — |
| Built-in Google Maps grounding | — | — | ✅ | — |
| Built-in semantic file search (`fileSearch`) | — | — | ✅ | — |
| Context caching (`cachedContent` resource) | — | — | ✅ | — |
| Tool-call mode `VALIDATED` | — | — | ✅ | — |
| `toolConfig.retrievalConfig` / `includeServerSideToolInvocations` | — | — | ✅ | — |
| `responseJsonSchema` (newer JSON Schema variant) | — | — | ✅ | — |
| `mediaResolution` (image/video token budget) | — | — | ✅ | — |
| `audioTimestamp`, `speechConfig` | — | — | ✅ | — |
| `enableEnhancedCivicAnswers` | — | — | ✅ | — |
| `routingConfig` / `modelSelectionConfig` | — | — | ✅ | — |
| `thinkingConfig.includeThoughts` detail control | — | — | ✅ (`reasoning.summary: "auto"` only maps to `true`) | — |
| `thinkingConfig.thinkingLevel` | — | — | ✅ (use `reasoning.effort`) | — |
| Per-Part `videoMetadata` (offset/FPS) | — | — | ✅ | — |
| Top-level `labels` (Vertex flavor) | — | — | ✅ | — |

For Messages specifically:
- **Prompt caching** — Anthropic's `cache_control: {"type": "ephemeral"}` markers on system blocks, message content blocks, tool definitions, document blocks, and the top-level request have no Open Responses equivalent. The `prompt_cache_key` and `prompt_cache_retention` session fields are silently omitted from the Messages payload.
- **Citations** — text-block `citations` are preserved via `OutputText.annotations`. The `citations: {"enabled": true}` opt-in on document blocks and tool results is not modeled by this gem.
- **Geographic inference routing** — Anthropic's `inference_geo` request field has no canonical Open Responses field. Response-side `usage.inference_geo` is preserved in `response.usage.input_tokens_details`.
- **API versioning / beta headers** — this gem produces no HTTP, so `anthropic-version`, `anthropic-beta`, and similar headers must be set on your HTTP client. Features behind a beta header (Files API, MCP, code execution containers, extended caching, etc.) still produce valid request payloads through this gem when their request-body shape is supported.

### Chat Completions-specific notes

Serializing a session without `model` set, or one that produces no messages at all, raises a `PromptBuilder::UnsupportedFormatError`.

Request-side mappings worth calling out:

| Canonical field / value | Chat Completions mapping |
|:---|:---|
| `instructions` | leading `{"role": "system", "content": ...}` message (use `session.developer(...)` if your model prefers `developer`) |
| `max_output_tokens` | `max_completion_tokens` |
| `safety_identifier` | `safety_identifier` (the legacy `user` field is not used) |
| `prompt_cache_key` / `prompt_cache_retention` | passed through directly |
| `text.format` | `response_format` (the OR-canonical flat `json_schema` is reshaped into `{"type": "json_schema", "json_schema": {...}}`) |
| `text.verbosity` | top-level `verbosity` |
| `reasoning.effort` | `reasoning_effort` |
| `tool_choice: {"type": "function", "name": ...}` | `{"type": "function", "function": {"name": ...}}` |
| `InputFile.file_id` | `{"type": "file", "file": {"file_id": ...}}` |
| `InputFile` with data URL (+ optional `filename`/`media_type`) | `{"type": "file", "file": {"filename": ..., "file_data": "data:<media_type>;base64,..."}}` |
| `InputImage` with data URL (+ `media_type`) | `{"type": "image_url", "image_url": {"url": "data:<media_type>;base64,..."}}` |

Chat Completions request features with no canonical Open Responses field are available through `session.extra` (`stop`, `seed`, `logit_bias`, `n`, `prediction`, `web_search_options`, `modalities`, `audio`). Features not exposed at all include `input_audio` content blocks, custom tools, `tool_choice: {"type": "allowed_tools", ...}`, and the deprecated `functions`, `function_call`, `max_tokens`, and `user` fields. Use the modern canonical fields when available (`tools`, `tool_choice`, `max_output_tokens`, `safety_identifier`, `prompt_cache_key`).

Response-side behavior and limitations:

- Responses with multiple choices (`n > 1`) parse only the first choice; additional candidates are dropped.
- Streaming chunks (`chat.completion.chunk` deltas) raise `UnsupportedFormatError` — this gem expects a fully assembled non-streaming response body.
- `system_fingerprint` is exposed on `response.provider_data`.
- `service_tier` is populated when present on the response.
- `message.annotations` (URL citations from `web_search_options`) are copied onto `OutputText.annotations`.
- Audio responses, custom tool calls, legacy `message.function_call`, and unknown response content block types are silently skipped because they have no canonical representation in this gem.
- `finish_reason` mappings: `stop`/`tool_calls`/`function_call` → `completed`, `length` → `incomplete`, `content_filter` → `failed`. The legacy `function_call` reason is included so older models still surface as completed.

### Anthropic Messages-specific mappings

The Messages API requires the `max_tokens` parameter, which is populated from `session.max_output_tokens`. Serializing a session without `max_output_tokens` set raises a `PromptBuilder::UnsupportedFormatError`.

A few features map between the canonical Open Responses format and the Messages API in non-obvious ways:

| Canonical field / value | Messages mapping |
|:---|:---|
| `InputImage.file_id` | `{"type": "image", "source": {"type": "file", "file_id": ...}}` (Files API beta) |
| `InputFile.file_id` | `{"type": "document", "source": {"type": "file", "file_id": ...}}` (Files API beta) |
| `FunctionCallOutput.status` ∈ `incomplete`, `failed`, `error` | `tool_result.is_error: true` |
| `safety_identifier` | `metadata.user_id` |
| `parallel_tool_calls: false` | `tool_choice.disable_parallel_tool_use: true` (forces `tool_choice.type` to `auto` if unset) |
| `reasoning.budget_tokens` | `thinking.budget_tokens` (with `thinking.type` defaulted to `enabled`) |
| `reasoning.effort` | `output_config.effort` (`low`, `medium`, `high`, `xhigh`, or `max`) |
| `reasoning.type: "adaptive"` | `thinking.type: "adaptive"` |
| `text.format.type: "json_schema"` | `output_config.format` (`type` and `schema` only; `name`, `description`, and `strict` are ignored) |
| `Tools::Definition#strict` | tool definition `strict: true` |
| `tool_choice: "required"` | `{"type": "any"}` |
| `tool_choice: {"type": "function", "name": ...}` | `{"type": "tool", "name": ...}` |

Response stop reasons are mapped to Open Responses statuses as follows: `end_turn`, `tool_use`, `stop_sequence`, and `pause_turn` → `completed`; `max_tokens` → `incomplete`; `refusal` → `failed`. When `stop_sequence` is matched, the matched text is exposed via `response.incomplete_details["stop_sequence"]`. Anthropic `stop_details` and response `container` metadata are exposed via `response.incomplete_details`. Additional usage details (`cache_creation` breakdown, `service_tier`, `inference_geo`, `server_tool_use`, and cache token counts) are surfaced through `response.usage.input_tokens_details`.

Built-in tool response content blocks (`server_tool_use`, `web_search_tool_result`, `web_fetch_tool_result`, `code_execution_tool_result`, `bash_code_execution_tool_result`, `tool_search_tool_result`, `mcp_tool_use`, `mcp_tool_result`, `container_upload`, `search_result`) are silently skipped on parse, since this gem has no canonical representation for them.

### Gemini-specific notes

Serializing a session without `model` set (the model belongs in the request URL, but it is validated at serialization time), or one that produces an empty `contents` array, raises a `PromptBuilder::UnsupportedFormatError`.

Request-side mappings worth calling out:

| Canonical field / value | Gemini mapping |
|:---|:---|
| `instructions` + `system`/`developer` messages | merged into `systemInstruction.parts[]` |
| `max_output_tokens` | `generationConfig.maxOutputTokens` |
| `temperature` / `top_p` | `generationConfig.temperature` / `topP` |
| `presence_penalty` / `frequency_penalty` | `generationConfig.presencePenalty` / `frequencyPenalty` |
| `top_logprobs: N` | `generationConfig.{responseLogprobs: true, logprobs: N}` |
| `text.format == "text"` | `generationConfig.responseMimeType = "text/plain"` |
| `text.format == "json_object"` | `generationConfig.responseMimeType = "application/json"` |
| `text.format == "json_schema"` | `generationConfig.responseMimeType = "application/json"` + `responseSchema` (read from `format.json_schema.schema` or `format.schema`) |
| `reasoning.budget_tokens` | `generationConfig.thinkingConfig.thinkingBudget` |
| `tool_choice: "auto"` / `"none"` / `"required"` | `toolConfig.functionCallingConfig.mode = AUTO` / `NONE` / `ANY` |
| `tool_choice: {"type": "function", "name": ...}` | `mode = ANY` + `allowedFunctionNames: [name]` |
| Tool definitions | single `tools[0].functionDeclarations[]` entry |

Content and message restrictions:

- Assistant messages map to `role: "model"`; consecutive same-role turns are merged automatically.
- `InputImage`, `InputFile`, and `InputVideo` are only supported in user messages; the same content on an assistant message is omitted.
- `InputImage` accepts any URL, a base64 data URL (with required `media_type`), or a Files API `file_id`.
- `InputFile` accepts any URL, a base64 data URL, or `file_id`. `media_type` is required when not inferable from a `filename` or URL extension. Recognized extensions cover documents (`pdf`, `txt`, `md`/`markdown`, `html`/`htm`, `csv`, `json`, `xml`, `rtf`), images (`png`, `jpg`/`jpeg`, `webp`, `heic`, `heif`), audio (`mp3`, `wav`, `aiff`, `aac`, `ogg`, `flac`), and video (`mp4`, `mov`, `webm`, `mpeg`/`mpg`).
- `InputVideo` requires a URL; raw bytes are not modeled.
- `RefusalContent` is dropped silently so a parsed Chat Completions refusal can sit in session history without breaking subsequent serialization.
- `Reasoning` items round-trip via `parts[].thought` with `thoughtSignature` preserved. `redacted_thinking`, `summary`, and unknown reasoning block types are silently skipped.
- `FunctionCall.arguments` must parse to a JSON object — Gemini's `functionCall.args` is a Struct.
- `FunctionCallOutput` content must be text-only (`InputText`/`OutputText` or a plain string); other content types are omitted. When `output` parses to a JSON object it is forwarded as the `functionResponse.response` Struct; otherwise it is wrapped as `{"result": ...}`. The output must reference a prior `FunctionCall` so its `name` can be resolved (Gemini's `functionResponse.name` is the tool name, not the call id).
- `Compaction` and `ItemReference` items are silently skipped.
- `tool_choice` without registered tools is omitted (along with unsupported `tool_choice` shapes).

Response-side limitations:

- Unknown response `Part` shapes (`inlineData`, `fileData`, `executableCode`, `codeExecutionResult`, `videoMetadata`, server-side `toolCall`/`toolResponse`, or any `Part` without a recognized content key) are silently skipped.
- Only `candidates[0]` is parsed. When `candidateCount > 1`, additional candidates are dropped (their index is preserved on `provider_data`).
- Function-call `id` from the response is preserved when present; otherwise the parser synthesizes `gemini_call_<seed>_<n>` so multiple calls in one response share a deterministic seed.
- `finishReason` mappings: `STOP` → `completed`; `MAX_TOKENS` → `incomplete`; `SAFETY`, `RECITATION`, `OTHER`, `BLOCKLIST`, `PROHIBITED_CONTENT`, `SPII`, `MALFORMED_FUNCTION_CALL`, `IMAGE_SAFETY`, `LANGUAGE`, `UNEXPECTED_TOOL_CALL`, `TOO_MANY_TOOL_CALLS`, `MODEL_ARMOR` → `failed`. `FINISH_REASON_UNSPECIFIED` is treated as nil.
- An empty `candidates` array combined with `promptFeedback.blockReason` is mapped to `failed`.
- `usageMetadata.cachedContentTokenCount`, `toolUsePromptTokenCount`, `promptTokensDetails`, `cacheTokensDetails`, and `toolUsePromptTokensDetails` populate `response.usage.input_tokens_details`. `thoughtsTokenCount` and `candidatesTokensDetails` populate `response.usage.output_tokens_details`.
- Response metadata with no canonical Open Responses slot is exposed on `response.provider_data`: `groundingMetadata`, `citationMetadata`, `urlContextMetadata`, `urlRetrievalMetadata`, `safetyRatings`, `groundingAttributions`, `avgLogprobs`, `logprobsResult`, `finishMessage`, candidate `index`, top-level `createTime`, and full `promptFeedback`. Streaming chunks are not parsed — this gem expects a fully assembled non-streaming response body.

### Converse-specific notes

Serializing a session without `model` set (populates the required `modelId` parameter) raises a `PromptBuilder::UnsupportedFormatError`.

Request-side restrictions worth calling out:

| Canonical field / value | Converse mapping |
|:---|:---|
| `instructions` + `system`/`developer` messages | merged into top-level `system` array |
| `max_output_tokens` | `inferenceConfig.maxTokens` |
| `temperature` / `top_p` | `inferenceConfig.temperature` / `inferenceConfig.topP` |
| `metadata` | `requestMetadata` with scalar values stringified |
| `service_tier` | `serviceTier.type` |
| `text.format.type == "json_schema"` | `outputConfig.textFormat` with `structure.jsonSchema` |
| `tool_choice: "auto"` | `{"auto": {}}` |
| `tool_choice: "required"` | `{"any": {}}` |
| `tool_choice: {"type": "function", "name": ...}` | `{"tool": {"name": ...}}` |

Content and message restrictions:

- The first message must have role `user`; the request raises if it doesn't. Consecutive same-role messages are merged automatically.
- `system` and `developer` messages must contain text only. Non-text content is omitted because Converse system blocks only map to `text`, `guardContent`, or `cachePoint`, and the latter two are not modeled by this gem.
- `InputImage` requires either base64 `data` or an `s3://` URI; content with an arbitrary public URL is omitted. `file_id` and `detail` have no Converse equivalent and are silently ignored.
- `InputFile` requires either a base64 data URL or an `s3://` URI; document `name` is auto-derived from `filename` / URL and sanitized to Bedrock's allowed character set (`[A-Za-z0-9 \-()\[\]]{1,256}`), with collisions disambiguated within a single request.
- `InputFile.file_id` is silently ignored because Converse does not accept provider file IDs for documents.
- `InputVideo` requires an `s3://` URI; a non-S3 URL is omitted, and raw bytes (`source.bytes`) cannot be sent because the canonical `InputVideo` content type does not model byte data.
- `InputImage`, `InputFile`, and `InputVideo` are only supported in user messages; the same content on an assistant message is omitted. `RefusalContent`, `OutputText.annotations`, and `OutputText.logprobs` are also dropped because Converse has no request-side representation for them.
- `Reasoning` items are silently skipped on the request side, so multi-turn extended-thinking + tool-use loops are not supported through this serializer (the response parser does decode `reasoningContent` blocks back into `Reasoning` items, but they cannot be sent back).
- `Compaction` and `ItemReference` items are silently skipped.
- `FunctionCall.arguments` must parse to a JSON object; non-object JSON values raise (Bedrock's `toolUse.input` requires an object).
- `FunctionCallOutput.output` content supports `InputText`/`OutputText`, `InputImage`, `InputFile`, and `InputVideo`, mapping to Converse `text`, `image`, `document`, and `video` tool result blocks. Converse also supports `json` and `searchResult` tool result blocks, but this gem has no canonical content types for them, so unsupported content is omitted. `FunctionCallOutput.status` is mapped: `completed` → `success`, `failed`/`incomplete` → `error`, anything else passes through or is dropped.
- `tool_choice: "none"` and `tool_choice` without registered tools are both omitted.
- Converse API request features with no canonical Open Responses field are available through `session.extra` (`stop_sequences`, `guardrail_config`, `additional_model_request_fields`, `additional_model_response_field_paths`, `performance_config`, `prompt_variables`) and content `extra` (`cache_point`). Features not exposed at all include `guardContent`, audio blocks, and `searchResult` blocks.
- The serialized payload includes `modelId` as a convenience; the Converse REST endpoint takes the model id in the URL path (`/model/{modelId}/converse`), and AWS REST-JSON services ignore unrecognized body members. Remove it from the body if you prefer a strictly minimal payload.

Response-side limitations:

- Unknown content block keys (e.g. `citationsContent`, `guardContent`) are silently skipped.
- `metrics.latencyMs`, `trace` (guardrail and prompt-router trace events), `additionalModelResponseFields`, `performanceConfig`, and the raw `serviceTier` object are exposed on `response.provider_data`. `response.service_tier` is also populated from `serviceTier.type`.
- `stopReason` mappings: `end_turn` / `tool_use` / `stop_sequence` → `completed`, `max_tokens` / `model_context_window_exceeded` → `incomplete`, `guardrail_intervened` / `content_filtered` / `malformed_model_output` / `malformed_tool_use` → `failed`. Unlike the Messages serializer, the matched stop sequence text is not surfaced separately because Converse does not echo it back unless you request provider-specific fields through `additionalModelResponseFieldPaths` (available via the `additional_model_response_field_paths` session extra; the requested fields appear on `response.provider_data`).
- `usage.cacheReadInputTokens` and `usage.cacheWriteInputTokens` populate `response.usage.input_tokens_details["cached_tokens"]` and `["cache_creation_input_tokens"]`. Cache writes require `cachePoint` markers in the request, which are emitted via the `cache_point` content extra.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "prompt_builder"
```

Then execute:
```bash
$ bundle
```

Or install it yourself as:
```bash
$ gem install prompt_builder
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/prompt_builder).

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
