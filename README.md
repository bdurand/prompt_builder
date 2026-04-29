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
  model: "gpt-4.1",
  instructions: "You are a helpful assistant.",
  temperature: 0.7
)

session.user("What is the capital of France?")
```

You can also pass an `input` shorthand to create a user message in one step:

```ruby
session = PromptBuilder::Session.new(
  model: "gpt-4.1",
  input: "What is the capital of France?"
)
```

### Conversation History

Build up a multi-turn conversation by adding messages:

```ruby
session = PromptBuilder::Session.new(model: "gpt-4.1")
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

Parse an API response back into an `PromptBuilder::Response` object using the matching serializer:

```ruby
# OpenAI Responses API
response = PromptBuilder::Serializers::OpenResponses.parse_response(JSON.parse(response_body))

# OpenAI Chat Completions API
response = PromptBuilder::Serializers::ChatCompletion.parse_response(JSON.parse(response_body))

# Anthropic Messages API
response = PromptBuilder::Serializers::Messages.parse_response(JSON.parse(response_body))
```

The `Response` object provides convenient accessors:

```ruby
response.text          # => "The capital of France is Paris."
response.completed?    # => true
response.has_tool_calls? # => false
response.usage         # => #<PromptBuilder::Usage input_tokens=25 output_tokens=12 ...>
```

### Agentic Tool Loops

You can register tools on a session, add the API response to the conversation, and let the session automatically dispatch tool calls:

```ruby
session = PromptBuilder::Session.new(model: "gpt-4.1")

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
) do |args|
  # Call your weather service here
  "72°F and sunny in #{args["city"]}"
end

session.user("What's the weather in Paris?")

loop do
  payload = session.request_payload(:chat_completion)
  response_body = call_api(payload)  # Your HTTP call
  response = PromptBuilder::Serializers::ChatCompletion.parse_response(response_body)

  session.add_response(response)
  break unless response.has_tool_calls?

  session.dispatch_tool_calls
end

puts session.items.last.content.first.text
```

The `add_response` method appends the model's output items (messages, tool calls, reasoning, etc.) to the session's conversation history. The `dispatch_tool_calls` method finds any pending function calls, invokes their handlers, and adds the results back to the conversation. This lets you loop until the model produces a final text response.

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
session = PromptBuilder::Session.new(model: "gpt-4.1")
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

Message content can be a plain string or an array of structured content objects for multi-modal input:

```ruby
session.user([
  {"type" => "input_text", "text" => "What is in this image?"},
  {"type" => "input_image", "image_url" => "https://example.com/photo.jpg"}
])
```

Supported content types:

| Type | Description |
|------|-------------|
| `input_text` | Text input |
| `input_image` | Image input (URL or base64) |
| `input_file` | File input |
| `input_video` | Video input |
| `output_text` | Text output from the model |
| `refusal` | Refusal content from the model |

### Configuration Options

Sessions support a wide range of configuration options that map to common API parameters:

```ruby
session = PromptBuilder::Session.new(
  model: "gpt-4.1",
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
