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
| `prompt_cache_key` | ❌ | ❌ | ❌ | ❌ |
| `reasoning` | `effort` key only | `budget_tokens`/`display`/`type` only | `budget_tokens` key only | ❌ |
| `safety_identifier` | ✅ → `user` | ✅ → `metadata.user_id` | ❌ | ❌ |
| `service_tier` | ✅ | `auto`/`standard_only` only | ❌ | ❌ |
| `store` | ✅ | ❌ | ❌ | ❌ |
| `stream` | ✅ | ✅ | endpoint-selected⁸ | ❌ |
| `stream_options` | `include_usage`/`include_obfuscation` only | ❌ | ❌ | ❌ |
| `text` | `format` key only | ❌ | `format` key only | ❌ |
| `top_logprobs` | ✅ | ❌ | ❌ | ❌ |
| `truncation` | ❌ | ❌ | ❌ | ❌ |

### Content Types

| Content Type | ChatCompletion | Messages | Gemini | Converse |
|:---|:---:|:---:|:---:|:---:|
| `InputText` | ✅ | ✅ | ✅ | ✅ |
| `InputImage` | user messages only⁷ | user messages only⁵ | user messages only⁶ | base64 or S3 URI only |
| `InputFile` | ❌ | user messages only¹ | user messages only⁶ | base64 or S3 URI only² |
| `InputVideo` | ❌ | ❌ | `video_url` required (public URL, gs://, or Files API) | S3 URI only |
| `OutputText` | ✅ | ✅ | ✅ | ✅ |
| `RefusalContent` | dropped⁹ | dropped⁹ | dropped⁹ | dropped⁹ |
| `Reasoning` items | ❌ | ✅³ | ✅⁴ | ❌ |
| `Compaction` items | ❌ | ❌ | ❌ | ❌ |
| `ItemReference` items | ❌ | ❌ | ❌ | ❌ |

¹ Messages format defaults to `application/pdf`; set `InputFile.media_type` to use a different document type.  
² Converse format infers the document type from the filename or file URL extension.  
³ Messages format only emits `thinking` blocks that include a cryptographic `signature`; unsigned blocks are silently dropped.  
⁴ Gemini format passes `thoughtSignature` through transparently. `redacted_thinking` blocks raise.  
⁵ Anthropic does not support a `detail` field on images; it is silently dropped.  
⁶ Gemini requires a Google-hosted URI (`gs://`, `https://generativelanguage.googleapis.com/`, or `https://storage.googleapis.com/`) — arbitrary public URLs raise. For files, set `media_type` or use a recognized `filename`/`file_url` extension.  
⁷ Chat Completions does not accept `InputImage.file_id` — the `image_file` content type is Assistants API only. Use `image_url` or base64 `data` instead. `InputFile` content has no Chat Completions equivalent.  
⁸ Gemini selects streaming by endpoint (`:streamGenerateContent`), not a request body field, so `session.stream` is silently ignored when serializing to Gemini.  
⁹ `RefusalContent` blocks are dropped silently from request messages so a parsed Chat Completions refusal can sit in session history without breaking subsequent `request_payload` calls. A message left empty after stripping is omitted entirely.

### Features Not Accessible Through Open Responses

These target API features are not available through the Open Responses canonical format because Open Responses does not expose the equivalent parameters:

| Feature | ChatCompletion | Messages | Gemini | Converse |
|:---|:---:|:---:|:---:|:---:|
| Audio input | ✅ | — | ✅ | — |
| Audio output / TTS | ✅ | — | ✅ | — |
| `top_k` sampling | — | ✅ | ✅ | — |
| `seed` | ✅ | — | ✅ | — |
| Stop sequences | ✅ | ✅ | ✅ | ✅ |
| `logit_bias` | ✅ | — | — | — |
| Multiple candidates (`n`) | ✅ | — | ✅ | — |
| Speculative decoding (`prediction`) | ✅ | — | — | — |
| Configurable safety thresholds | — | — | ✅ | — |
| Guardrail policies | — | — | — | ✅ |
| Cross-region routing (inference profiles) | — | — | — | ✅ |
| Built-in web search | — | ✅ | ✅ | — |
| Built-in code execution | — | ✅ | ✅ | — |
| Built-in computer use | — | ✅ | — | — |
| Built-in bash / text editor / memory tools | — | ✅ | — | — |

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
