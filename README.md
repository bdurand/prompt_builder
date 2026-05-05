# PromptBuilder

:construction: NOT RELEASED :construction:

[![Continuous Integration](https://github.com/bdurand/prompt_builder/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/prompt_builder/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/prompt_builder.svg)](https://badge.fury.io/rb/prompt_builder)

This gem provides a Ruby DSL for building and parsing LLM API request payloads. It uses the [OpenAI Responses API](https://platform.openai.com/docs/api-reference/responses) as its canonical data model and includes serializers that can convert to and from the [OpenAI Chat Completions API](https://platform.openai.com/docs/api-reference/chat) and [Anthropic Messages API](https://docs.anthropic.com/en/api/messages) formats. It also includes a simple tool registry for defining tools that can be called by the model.

This gem does **not** include any HTTP client code. It is designed to be used with whatever HTTP library you prefer. You build a request payload, send it to the API yourself, and then parse the response back into Ruby objects.

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

### Sessions

The `PromptBuilder::Session` class is the main entry point. A session holds the model configuration, conversation history, and tool definitions needed to build a request payload.

```ruby
session = PromptBuilder::Session.new(
  model: "gpt-5.4",
  instructions: "You are a helpful assistant.",
  temperature: 0.7
)

session.user("What is the capital of France?")
```

You can also pass an `input` shorthand to create a user message in one step:

```ruby
session = PromptBuilder::Session.new(
  model: "gpt-5.4",
  input: "What is the capital of France?"
)
```

### Conversation History

Build up a multi-turn conversation by adding messages:

```ruby
session = PromptBuilder::Session.new(model: "gpt-5.4")
session.system("You are a helpful assistant.")
session.user("Hello!")
session.assistant("Hi there! How can I help you today?")
session.user("What's the weather like?")
```

Messages support the roles `user`, `assistant`, `system`, and `developer`.

### Serializing Requests

Once you've built a session, serialize it to a request payload for the API you want to call. Three formats are supported:

**OpenAI Responses API** (the canonical format):

```ruby
payload = session.to_h
# or
payload = session.request_payload(:open_responses)
```

**OpenAI Chat Completions API**:

```ruby
payload = session.request_payload(:chat_completion)
```

**Anthropic Messages API**:

```ruby
payload = session.request_payload(:messages)
```

The payload is a plain Ruby `Hash` that you can convert to JSON and send to the API with any HTTP client:

```ruby
require "net/http"
require "json"

uri = URI("https://api.openai.com/v1/responses")
request = Net::HTTP::Post.new(uri)
request["Authorization"] = "Bearer #{api_key}"
request["Content-Type"] = "application/json"
request.body = JSON.generate(session.to_h)

response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
  http.request(request)
end
```

### Parsing Responses

Parse an API response back into an `PromptBuilder::Response` object using `Response.parse` with a serializer symbol:

```ruby
# OpenAI Responses API
response = PromptBuilder::Response.parse(JSON.parse(response_body), :open_responses)

# OpenAI Chat Completions API
response = PromptBuilder::Response.parse(JSON.parse(response_body), :chat_completion)

# Anthropic Messages API
response = PromptBuilder::Response.parse(JSON.parse(response_body), :messages)
```

You can also pass a serializer class directly:

```ruby
response = PromptBuilder::Response.parse(JSON.parse(response_body), PromptBuilder::Serializers::ChatCompletion)
```

The `Response` object provides convenient accessors:

```ruby
response.text          # => "The capital of France is Paris."
response.completed?    # => true
response.has_tool_calls? # => false
response.usage         # => #<PromptBuilder::Usage input_tokens=25 output_tokens=12 ...>
```

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
  break unless response.has_tool_calls?

  # Invoke tool handlers and add their outputs back to the conversation
  session.items.each do |item|
    next unless item.is_a?(PromptBuilder::Items::FunctionCall)
    result = call_tool(item.name, item.parsed_arguments)  # Your dispatch logic
    session.add_item(PromptBuilder::Items::FunctionCallOutput.new(call_id: item.call_id, output: result.to_s))
  end
end

puts session.items.last.content.first.text
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

### Content Types

Message content can be a plain string or an array of structured content objects for multi-modal input. Content can be provided as raw Hashes or as `PromptBuilder::Content` objects.

**Images**

Send an image by URL or as base64-encoded data:

```ruby
# Image from a URL
session.user([
  PromptBuilder::Content::InputText.new(text: "What is in this image?"),
  PromptBuilder::Content::InputImage.new(image_url: "https://example.com/photo.jpg")
])

# Image with a detail level hint
session.user([
  PromptBuilder::Content::InputText.new(text: "Describe this image in detail."),
  PromptBuilder::Content::InputImage.new(
    image_url: "https://example.com/photo.jpg",
    detail: "high"
  )
])

# Base64-encoded image
session.user([
  PromptBuilder::Content::InputText.new(text: "What is in this image?"),
  PromptBuilder::Content::InputImage.new(
    data: Base64.strict_encode64(File.read("photo.png")),
    media_type: "image/png"
  )
])
```

**Files**

Attach a file by URL or as base64-encoded data:

```ruby
# File from a URL
session.user([
  PromptBuilder::Content::InputText.new(text: "Summarize this document."),
  PromptBuilder::Content::InputFile.new(file_url: "https://example.com/report.pdf")
])

# Base64-encoded file with a filename and media type
session.user([
  PromptBuilder::Content::InputText.new(text: "What does this spreadsheet contain?"),
  PromptBuilder::Content::InputFile.new(
    file_data: Base64.strict_encode64(File.read("data.csv")),
    filename: "data.csv",
    media_type: "text/csv"
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
  PromptBuilder::Content::InputVideo.new(video_url: "https://example.com/clip.mp4")
])
```

**Using Hashes**

You can also pass plain Hashes instead of content objects:

```ruby
session.user([
  {"type" => "input_text", "text" => "What is in this image?"},
  {"type" => "input_image", "image_url" => "https://example.com/photo.jpg"}
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
  store: true,
  metadata: {"user_id" => "123"}
)
```

### Serialization and Persistence

Sessions and responses can be serialized to and from Hashes for storage or transmission:

```ruby
# Serialize a session to a Hash
hash = session.to_h

# Restore a session from a Hash
restored_session = PromptBuilder::Session.from_h(hash)
```

This makes it straightforward to persist conversation state in a database or cache between requests.

## Serializer Compatibility

The Open Responses format is the canonical data model for this gem. When serializing to other formats, some features may not be available because the target API does not support them (raising `UnsupportedFormatError`) or because the Open Responses format does not expose parameters unique to the target API.

### Session Fields

The following table shows which session configuration fields are supported by each serializer. ❌ means the field raises `UnsupportedFormatError`. Partial support is noted inline.

| Session Field | ChatCompletion | Messages | Gemini | Converse |
|:---|:---:|:---:|:---:|:---:|
| `background` | ❌ | ❌ | ❌ | ❌ |
| `frequency_penalty` | ✅ | ❌ | ❌ | ❌ |
| `include` | ❌ | ❌ | ❌ | ❌ |
| `max_tool_calls` | ❌ | ❌ | ❌ | ❌ |
| `metadata` | ✅ | `user_id` key only | ❌ | ❌ |
| `parallel_tool_calls` | ✅ | ✅ | ❌ | ❌ |
| `presence_penalty` | ✅ | ❌ | ❌ | ❌ |
| `prompt_cache_key` | ✅ | ❌ | ❌ | ❌ |
| `reasoning` | `effort` key only | `budget_tokens`/`display`/`type` only | `budget_tokens` key only | ❌ |
| `safety_identifier` | ✅ | ✅ → `metadata.user_id` | ❌ | ❌ |
| `service_tier` | ✅ | `auto`/`standard_only` only | ❌ | ❌ |
| `store` | ✅ | ❌ | ❌ | ❌ |
| `stream` | ✅ | ✅ | endpoint-selected⁸ | ❌ |
| `stream_options` | `include_usage`/`include_obfuscation` only | ❌ | ❌ | ❌ |
| `text` | `format`/`verbosity` only | ❌ | `format` key only | ❌ |
| `top_logprobs` | ✅ | ❌ | ✅ → `responseLogprobs`/`logprobs` | ❌ |
| `truncation` | ❌ | ❌ | ❌ | ❌ |

### Content Types

| Content Type | ChatCompletion | Messages | Gemini | Converse |
|:---|:---:|:---:|:---:|:---:|
| `InputText` | ✅ | ✅ | ✅ | ✅ |
| `InputImage` | user messages only⁷ | user messages only⁵ | user messages only⁶ | base64 or S3 URI only |
| `InputFile` | user messages only¹⁰ | user messages only¹ | user messages only⁶ | base64 or S3 URI only² |
| `InputVideo` | ❌ | ❌ | `video_url` required (public URL, gs://, or Files API) | S3 URI only |
| `OutputText` | ✅ (annotations dropped on request)¹¹ | ✅ | ✅ | ✅ |
| `RefusalContent` | dropped⁹ | dropped⁹ | dropped⁹ | dropped⁹ |
| `Reasoning` items | ❌ | ✅³ | ✅⁴ | ❌ |
| `Compaction` items | ❌ | ❌ | ❌ | ❌ |
| `ItemReference` items | ❌ | ❌ | ❌ | ❌ |

¹ Messages format defaults to `application/pdf` for base64 sources; set `InputFile.media_type` to use a different document type. `file_id` is mapped to a `file` source for the Anthropic Files API beta — set the appropriate `anthropic-beta: files-api-2025-04-14` header in your HTTP client.  
² Converse format infers the document type from the filename or file URL extension.  
³ Messages format only emits `thinking` blocks that include a cryptographic `signature`; unsigned blocks are silently dropped.  
⁴ Gemini format passes `thoughtSignature` through transparently. `redacted_thinking` blocks raise.  
⁵ Anthropic does not support a `detail` field on images; it is silently dropped. `file_id` is mapped to a `file` source (Anthropic Files API beta).  
⁶ Gemini requires a Google-hosted URI (`gs://`, `https://generativelanguage.googleapis.com/`, or `https://storage.googleapis.com/`) — arbitrary public URLs raise. For files, set `media_type` or use a recognized `filename`/`file_url` extension.  
⁷ Chat Completions does not accept `InputImage.file_id` — the `image_file` content type is Assistants API only. Use `image_url` or base64 `data` instead.  
⁸ Gemini selects streaming by endpoint (`:streamGenerateContent`), not a request body field, so `session.stream` is silently ignored when serializing to Gemini.  
⁹ `RefusalContent` blocks are dropped silently from request messages so a parsed Chat Completions refusal can sit in session history without breaking subsequent `request_payload` calls. A message left empty after stripping is omitted entirely.  
¹⁰ Chat Completions sends `InputFile` as a `{"type": "file", "file": {...}}` content block. `file_id` (Files API) and base64 `file_data` (with optional `filename`/`media_type`; defaults to `application/pdf`) are supported. `file_url` raises because Chat Completions has no remote-URL form for files.  
¹¹ `OutputText.annotations` (e.g. URL citations from `web_search_options`) are parsed onto the assistant message and round-trip through session history, but are dropped silently on request serialization since Chat Completions has no request-side equivalent.

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
| `logit_bias` | ✅ | — | — | — |
| Multiple candidates (`n`) | ✅ | — | ✅ | — |
| Speculative decoding (`prediction`) | ✅ | — | — | — |
| `tool_choice` `allowed_tools` shape | ✅ | — | — | — |
| Custom (non-function) tool types | ✅ | — | — | — |
| Built-in web search (`web_search_options`) | ✅ | ✅ | ✅ | — |
| Configurable safety thresholds | — | — | ✅ | — |
| Guardrail policies (`guardrailConfig`, `guardContent`) | — | — | — | ✅ |
| Cross-region routing (inference profiles) | — | — | — | ✅ |
| Prompt caching (`cache_control` markers) | — | ✅ | — | — |
| Prompt caching (`cachePoint` blocks) | — | — | — | ✅ |
| Citations on documents and tool results | — | ✅ | — | ✅ |
| Bedrock Prompt Management variables (`promptVariables`) | — | — | — | ✅ |
| `search_result` content blocks | — | ✅ | — | — |
| MCP connectors (`mcp_servers`) | — | ✅ | — | — |
| Code execution `container` reuse | — | ✅ | — | — |
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
| `thinkingConfig.includeThoughts` (request thought parts) | — | — | ✅ | — |
| Per-Part `videoMetadata` (offset/FPS) | — | — | ✅ | — |
| Top-level `labels` (Vertex flavor) | — | — | ✅ | — |

For Messages specifically:
- **Prompt caching** — Anthropic's `cache_control: {"type": "ephemeral"}` markers on system blocks, message content blocks, tool definitions, and document blocks have no Open Responses equivalent. The `prompt_cache_key` session field raises `UnsupportedFormatError` rather than silently doing nothing.
- **Citations** — both the `citations: {"enabled": true}` opt-in on documents/tool results and the `citations` array returned on response text blocks are not modeled by this gem. Response text blocks with citations are parsed but the citation data is dropped.
- **API versioning / beta headers** — this gem produces no HTTP, so `anthropic-version`, `anthropic-beta`, and similar headers must be set on your HTTP client. Features behind a beta header (Files API, MCP, code execution containers, extended caching, etc.) still produce valid request payloads through this gem when their request-body shape is supported.

### Chat Completions-specific notes

Request-side mappings worth calling out:

| Canonical field / value | Chat Completions mapping |
|:---|:---|
| `instructions` | leading `{"role": "system", "content": ...}` message (use `session.developer(...)` if your model prefers `developer`) |
| `max_output_tokens` | `max_completion_tokens` |
| `safety_identifier` | `safety_identifier` (the legacy `user` field is not used) |
| `text.format` | `response_format` (the OR-canonical flat `json_schema` is reshaped into `{"type": "json_schema", "json_schema": {...}}`) |
| `text.verbosity` | top-level `verbosity` |
| `reasoning.effort` | `reasoning_effort` |
| `tool_choice: {"type": "function", "name": ...}` | `{"type": "function", "function": {"name": ...}}` |
| `InputFile.file_id` | `{"type": "file", "file": {"file_id": ...}}` |
| `InputFile.file_data` (+ optional `filename`/`media_type`) | `{"type": "file", "file": {"filename": ..., "file_data": "data:<media_type>;base64,..."}}` (defaults to `application/pdf`) |
| `InputImage.data` (+ `media_type`) | `{"type": "image_url", "image_url": {"url": "data:<media_type>;base64,..."}}` |

Response-side limitations:

- Only `choices[0]` is parsed. Callers using `n > 1` will not see additional candidates.
- Streaming chunks (`chat.completion.chunk` deltas) are not parsed — this gem expects a fully assembled non-streaming response body.
- `system_fingerprint` is dropped (no canonical Open Responses slot).
- `service_tier` is populated when present on the response.
- `message.annotations` (URL citations from `web_search_options`) are copied onto `OutputText.annotations`.
- `finish_reason` mappings: `stop`/`tool_calls`/`function_call` → `completed`, `length` → `incomplete`, `content_filter` → `failed`. The legacy `function_call` reason is included so older models still surface as completed.

### Anthropic Messages-specific mappings

A few features map between the canonical Open Responses format and the Messages API in non-obvious ways:

| Canonical field / value | Messages mapping |
|:---|:---|
| `InputImage.file_id` | `{"type": "image", "source": {"type": "file", "file_id": ...}}` (Files API beta) |
| `InputFile.file_id` | `{"type": "document", "source": {"type": "file", "file_id": ...}}` (Files API beta) |
| `FunctionCallOutput.status` ∈ `incomplete`, `failed`, `error` | `tool_result.is_error: true` |
| `safety_identifier` | `metadata.user_id` |
| `parallel_tool_calls: false` | `tool_choice.disable_parallel_tool_use: true` (forces `tool_choice.type` to `auto` if unset) |
| `reasoning.budget_tokens` | `thinking.budget_tokens` (with `thinking.type` defaulted to `enabled`) |
| `tool_choice: "required"` | `{"type": "any"}` |
| `tool_choice: {"type": "function", "name": ...}` | `{"type": "tool", "name": ...}` |

Response stop reasons are mapped to Open Responses statuses as follows: `end_turn`, `tool_use`, `stop_sequence`, and `pause_turn` → `completed`; `max_tokens` → `incomplete`; `refusal` → `failed`. When `stop_sequence` is matched, the matched text is exposed via `response.incomplete_details["stop_sequence"]`. Additional usage details (`cache_creation` breakdown, `service_tier`, cache token counts) are surfaced through `response.usage.input_tokens_details`.

Built-in tool response content blocks (`server_tool_use`, `web_search_tool_result`, `code_execution_tool_result`, `mcp_tool_use`, `mcp_tool_result`, `container_upload`, `search_result`) raise `UnsupportedFormatError` on parse rather than being silently dropped, since dropping them would lose information from the assistant turn and break round-tripping.

### Gemini-specific notes

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
- `InputImage`, `InputFile`, and `InputVideo` are only supported in user messages; the same content on an assistant message raises.
- `InputImage` accepts a `gs://` / `https://generativelanguage.googleapis.com/` / `https://storage.googleapis.com/` URL, base64 `data` (with required `media_type`), or a Files API `file_id`. Arbitrary public URLs raise — Gemini will not fetch them.
- `InputFile` accepts the same URL prefixes, base64 `file_data`, or `file_id`. `media_type` is required when not inferable from a `filename` or URL extension. Recognized extensions: `pdf`, `txt`, `md`/`markdown`, `html`/`htm`, `csv`, `json`, `xml`, `rtf`.
- `InputVideo` requires `video_url` pointing at a Google-hosted URI; raw bytes are not modeled.
- `RefusalContent` is dropped silently so a parsed Chat Completions refusal can sit in session history without breaking subsequent serialization.
- `Reasoning` items round-trip via `parts[].thought` with `thoughtSignature` preserved. `redacted_thinking` and `summary` blocks raise; unknown reasoning block types raise rather than being silently dropped.
- `FunctionCall.arguments` must parse to a JSON object — Gemini's `functionCall.args` is a Struct.
- `FunctionCallOutput` content must be text-only (`InputText`/`OutputText` or a plain string). When `output` parses to a JSON object it is forwarded as the `functionResponse.response` Struct; otherwise it is wrapped as `{"result": ...}`. The output must reference a prior `FunctionCall` so its `name` can be resolved (Gemini's `functionResponse.name` is the tool name, not the call id).
- `Compaction` and `ItemReference` items raise.
- `tool_choice` without registered tools raises (except `tool_choice: "none"`).

Response-side limitations:

- Unknown response `Part` shapes (`inlineData`, `fileData`, `executableCode`, `codeExecutionResult`, `videoMetadata`, server-side `toolCall`/`toolResponse`, or any `Part` without a recognized content key) raise `UnsupportedFormatError` rather than being silently dropped.
- Only `candidates[0]` is parsed. When `candidateCount > 1`, additional candidates are dropped (their index is preserved on `provider_data`).
- Function-call `id` from the response is dropped; the parser synthesizes `gemini_call_<seed>_<n>` so multiple calls in one response share a deterministic seed.
- `finishReason` mappings: `STOP` → `completed`; `MAX_TOKENS` → `incomplete`; `SAFETY`, `RECITATION`, `OTHER`, `BLOCKLIST`, `PROHIBITED_CONTENT`, `SPII`, `MALFORMED_FUNCTION_CALL`, `IMAGE_SAFETY`, `LANGUAGE`, `UNEXPECTED_TOOL_CALL`, `TOO_MANY_TOOL_CALLS`, `MODEL_ARMOR` → `failed`. `FINISH_REASON_UNSPECIFIED` is treated as nil.
- An empty `candidates` array combined with `promptFeedback.blockReason` is mapped to `failed`.
- `usageMetadata.cachedContentTokenCount`, `toolUsePromptTokenCount`, `promptTokensDetails`, `cacheTokensDetails`, and `toolUsePromptTokensDetails` populate `response.usage.input_tokens_details`. `thoughtsTokenCount` and `candidatesTokensDetails` populate `response.usage.output_tokens_details`.
- Response metadata with no canonical Open Responses slot is exposed on `response.provider_data`: `groundingMetadata`, `citationMetadata`, `urlContextMetadata`, `urlRetrievalMetadata`, `safetyRatings`, `groundingAttributions`, `avgLogprobs`, `logprobsResult`, `finishMessage`, candidate `index`, top-level `createTime`, and full `promptFeedback`. Streaming chunks are not parsed — this gem expects a fully assembled non-streaming response body.

### Converse-specific notes

Request-side restrictions worth calling out:

| Canonical field / value | Converse mapping |
|:---|:---|
| `instructions` + `system`/`developer` messages | merged into top-level `system` array |
| `max_output_tokens` | `inferenceConfig.maxTokens` |
| `temperature` / `top_p` | `inferenceConfig.temperature` / `inferenceConfig.topP` |
| `tool_choice: "required"` | `{"any": {}}` |
| `tool_choice: {"type": "function", "name": ...}` | `{"tool": {"name": ...}}` |

Content and message restrictions:

- The first message must have role `user`; the request raises if it doesn't. Consecutive same-role messages are merged automatically.
- `InputImage` requires either base64 `data` or an `s3://` URI; arbitrary public URLs raise. `file_id` and `detail` have no Converse equivalent and are ignored or rejected.
- `InputFile` requires either base64 `file_data` or an `s3://` URI; document `name` is auto-derived from `filename` / `file_url` and sanitized to Bedrock's allowed character set (`[A-Za-z0-9 \-()\[\]]{1,256}`), with collisions disambiguated within a single request.
- `InputVideo` requires an `s3://` URI; raw bytes (`source.bytes`) cannot be sent because the canonical `InputVideo` content type does not model byte data.
- `InputImage`, `InputFile`, and `InputVideo` are only supported in user messages; the same content on an assistant message raises. `RefusalContent` is dropped silently so a parsed Chat Completions refusal can sit in session history without breaking subsequent serialization.
- `Reasoning` items raise on the request side, so multi-turn extended-thinking + tool-use loops are not supported through this serializer (the response parser does decode `reasoningContent` blocks back into `Reasoning` items, but they cannot be sent back).
- `Compaction` and `ItemReference` items raise.
- `FunctionCall.arguments` must parse to a JSON object; non-object JSON values raise (Bedrock's `toolUse.input` requires an object).
- `FunctionCallOutput.output` content is restricted to `InputText`/`OutputText` and `InputImage`. The Converse `toolResult.content` block also accepts `document`, `video`, and `json`; all three raise here. `FunctionCallOutput.status` is mapped: `completed` → `success`, `failed`/`incomplete` → `error`, anything else passes through or is dropped.
- `tool_choice: "none"` and `tool_choice` without registered tools both raise.

Response-side limitations:

- Unknown content block keys (e.g. `citationsContent`, `guardContent`) raise `UnsupportedFormatError` rather than being silently dropped.
- `metrics.latencyMs`, `trace` (guardrail and reasoning trace events), `additionalModelResponseFields`, and `performanceConfig` echoes are dropped.
- `stopReason` mappings: `end_turn` / `tool_use` / `stop_sequence` → `completed`, `max_tokens` → `incomplete`, `guardrail_intervened` / `content_filtered` → `failed`. Unlike the Messages serializer, the matched stop sequence text is not surfaced separately because Converse does not echo it back.
- `usage.cacheReadInputTokens` and `usage.cacheWriteInputTokens` populate `response.usage.input_tokens_details["cached_tokens"]` and `["cache_creation_input_tokens"]`. Cache writes still require `cachePoint` markers in the request, which this gem cannot produce.

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
