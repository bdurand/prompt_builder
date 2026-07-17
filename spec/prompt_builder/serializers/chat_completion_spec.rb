# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Serializers::ChatCompletion do
  before { PromptBuilder.reset_tool_registry! }

  describe ".request_payload" do
    it "converts a session to OpenAI Chat Completions format" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        instructions: "You are helpful.",
        temperature: 0.7,
        max_output_tokens: 1024
      )
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["model"]).to eq("gpt-4o")
      expect(h["temperature"]).to eq(0.7)
      expect(h["max_completion_tokens"]).to eq(1024)
      expect(h["messages"].length).to eq(2)
      expect(h["messages"][0]).to eq({"role" => "system", "content" => "You are helpful."})
      expect(h["messages"][1]["role"]).to eq("user")
      expect(h["messages"][1]["content"]).to eq([{"type" => "text", "text" => "Hello"}])
    end

    it "inserts instructions after the last system or developer message" do
      session = PromptBuilder::Session.new(model: "gpt-4o", instructions: "Base instruction")
      session.system("Extra system context")
      session.developer("Developer note")
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["messages"].length).to eq(4)
      expect(h["messages"][0]).to eq({"role" => "system", "content" => [{"type" => "text", "text" => "Extra system context"}]})
      expect(h["messages"][1]["role"]).to eq("developer")
      expect(h["messages"][2]).to eq({"role" => "system", "content" => "Base instruction"})
      expect(h["messages"][3]["role"]).to eq("user")
    end

    it "raises when model is missing" do
      session = PromptBuilder::Session.new
      session.user("Hello")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires session.model/)
    end

    it "raises when there are no messages" do
      session = PromptBuilder::Session.new(model: "gpt-4o")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /at least one message/)
    end

    it "converts tool definitions" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.register_tool(
        "get_weather",
        description: "Get weather",
        parameters: {"type" => "object", "properties" => {"city" => {"type" => "string"}}}
      ) { |_| "sunny" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tools"].length).to eq(1)
      tool = h["tools"][0]
      expect(tool["type"]).to eq("function")
      expect(tool["function"]["name"]).to eq("get_weather")
      expect(tool["function"]["description"]).to eq("Get weather")
      expect(tool["function"]["parameters"]).to eq({"type" => "object", "properties" => {"city" => {"type" => "string"}}})
    end

    it "combines an assistant message with sibling FunctionCall items" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Weather?")
      session.assistant("Let me check.")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "get_weather", call_id: "call_1", arguments: '{"city":"London"}'
      ))

      h = described_class.request_payload(session)
      messages = h["messages"]
      expect(messages.length).to eq(2)

      assistant_msg = messages[1]
      expect(assistant_msg["role"]).to eq("assistant")
      expect(assistant_msg["content"]).to eq([{"type" => "text", "text" => "Let me check."}])
      expect(assistant_msg["tool_calls"].length).to eq(1)
      expect(assistant_msg["tool_calls"][0]["function"]["name"]).to eq("get_weather")
    end

    it "silently skips Compaction items" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Compaction.new(encrypted_content: "abc"))

      h = described_class.request_payload(session)
      expect(h["messages"].length).to eq(1)
      expect(h["messages"][0]["role"]).to eq("user")
    end

    it "silently skips ItemReference items" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::ItemReference.new(id: "msg_1"))

      h = described_class.request_payload(session)
      expect(h["messages"].length).to eq(1)
      expect(h["messages"][0]["role"]).to eq("user")
    end

    it "emits empty string for nil FunctionCallOutput.output" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "ping", call_id: "call_1", arguments: "{}"
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "call_1", output: nil
      ))

      h = described_class.request_payload(session)
      tool_msg = h["messages"].last
      expect(tool_msg["role"]).to eq("tool")
      expect(tool_msg["content"]).to eq("")
    end

    it "omits InputImage with file_id (Chat Completions has no image_file equivalent)" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(file_id: "file_abc123")]
      ))

      h = described_class.request_payload(session)
      expect(h["messages"]).to eq([{"role" => "user", "content" => [{"type" => "text", "text" => "Hi"}]}])
    end

    it "converts function call items to tool_calls on assistant messages" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Weather?")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "get_weather", call_id: "call_1", arguments: '{"city":"London"}'
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "call_1", output: "72F sunny"
      ))

      h = described_class.request_payload(session)
      messages = h["messages"]
      expect(messages.length).to eq(3) # user, assistant+tool_calls, tool

      assistant_msg = messages[1]
      expect(assistant_msg["role"]).to eq("assistant")
      expect(assistant_msg["tool_calls"].length).to eq(1)
      expect(assistant_msg["tool_calls"][0]["id"]).to eq("call_1")
      expect(assistant_msg["tool_calls"][0]["function"]["name"]).to eq("get_weather")

      tool_msg = messages[2]
      expect(tool_msg["role"]).to eq("tool")
      expect(tool_msg["tool_call_id"]).to eq("call_1")
      expect(tool_msg["content"]).to eq("72F sunny")
    end

    it "silently skips reasoning items" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        content: [{"type" => "text", "text" => "thinking..."}]
      ))
      session.user("Hello")

      h = described_class.request_payload(session)
      messages = h["messages"]
      expect(messages.length).to eq(1)
      expect(messages[0]["role"]).to eq("user")
    end

    it "converts InputFile with file_id to a file content block" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_id: "file-abc123")]
      ))

      h = described_class.request_payload(session)
      expect(h["messages"][0]["content"]).to eq([
        {"type" => "file", "file" => {"file_id" => "file-abc123"}}
      ])
    end

    it "converts InputFile with base64 data URL to a file block" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(
          url: "data:application/pdf;base64,JVBERi0xLjQK",
          filename: "report.pdf",
          media_type: "application/pdf"
        )]
      ))

      h = described_class.request_payload(session)
      block = h["messages"][0]["content"][0]
      expect(block["type"]).to eq("file")
      expect(block["file"]["filename"]).to eq("report.pdf")
      expect(block["file"]["file_data"]).to eq("data:application/pdf;base64,JVBERi0xLjQK")
    end

    it "converts InputFile with data URL without explicit media_type" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(
          url: "data:application/octet-stream;base64,JVBERi0xLjQK",
          filename: "report.pdf"
        )]
      ))

      h = described_class.request_payload(session)
      block = h["messages"][0]["content"][0]
      expect(block["file"]["file_data"]).to start_with("data:application/octet-stream;base64,")
    end

    it "inlines text-based InputFile (text/html) as text content" do
      html = "<h1>Hello</h1>"
      encoded = [html].pack("m0")
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(
          url: "data:text/html;base64,#{encoded}",
          filename: "page.html",
          media_type: "text/html"
        )]
      ))

      h = described_class.request_payload(session)
      block = h["messages"][0]["content"][0]
      expect(block).to eq({"type" => "text", "text" => html})
    end

    it "inlines text-based InputFile (application/json) as text content" do
      json = '{"key": "value"}'
      encoded = [json].pack("m0")
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(
          url: "data:application/json;base64,#{encoded}",
          filename: "data.json",
          media_type: "application/json"
        )]
      ))

      h = described_class.request_payload(session)
      block = h["messages"][0]["content"][0]
      expect(block).to eq({"type" => "text", "text" => json})
    end

    it "inlines text-based InputFile (text/csv) as text content using data URL mime" do
      csv = "name,age\nAlice,30"
      encoded = [csv].pack("m0")
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(
          url: "data:text/csv;base64,#{encoded}",
          filename: "data.csv"
        )]
      ))

      h = described_class.request_payload(session)
      block = h["messages"][0]["content"][0]
      expect(block).to eq({"type" => "text", "text" => csv})
    end

    it "omits InputFile that has only a url (no Chat Completions representation)" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(url: "https://example.com/doc.pdf")]
      ))

      h = described_class.request_payload(session)
      expect(h["messages"]).to eq([{"role" => "user", "content" => [{"type" => "text", "text" => "Hi"}]}])
    end

    it "omits InputFile in non-user messages" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::InputFile.new(file_id: "file-abc")]
      ))

      h = described_class.request_payload(session)
      expect(h["messages"]).to eq([{"role" => "user", "content" => [{"type" => "text", "text" => "Hi"}]}])
    end

    it "omits InputVideo content" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputVideo.new(url: "https://example.com/video.mp4")]
      ))

      h = described_class.request_payload(session)
      expect(h["messages"]).to eq([{"role" => "user", "content" => [{"type" => "text", "text" => "Hi"}]}])
    end

    it "drops RefusalContent silently so a parsed refusal can stay in session history" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hello")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::RefusalContent.new(refusal: "I cannot help.")]
      ))
      session.user("Try again")

      h = described_class.request_payload(session)
      roles = h["messages"].map { |m| m["role"] }
      # The refusal-only assistant message is skipped entirely.
      expect(roles).to eq(["user", "user"])
    end

    it "converts InputImage to image_url format" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [
          PromptBuilder::Content::InputText.new(text: "What's in this image?"),
          PromptBuilder::Content::InputImage.new(url: "https://example.com/img.png", detail: "high")
        ]
      ))

      h = described_class.request_payload(session)
      content = h["messages"][0]["content"]
      expect(content.length).to eq(2)
      expect(content[0]).to eq({"type" => "text", "text" => "What's in this image?"})
      expect(content[1]).to eq({
        "type" => "image_url",
        "image_url" => {"url" => "https://example.com/img.png", "detail" => "high"}
      })
    end

    it "converts InputImage with base64 data" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(url: "data:image/png;base64,abc123")]
      ))

      h = described_class.request_payload(session)
      content = h["messages"][0]["content"]
      expect(content[0]["type"]).to eq("image_url")
      expect(content[0]["image_url"]["url"]).to eq("data:image/png;base64,abc123")
    end

    it "converts tool_choice string values" do
      session = PromptBuilder::Session.new(model: "gpt-4o", tool_choice: "auto")
      session.register_tool("test") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tool_choice"]).to eq("auto")
    end

    it "converts specific function tool_choice" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        tool_choice: {"type" => "function", "name" => "get_weather"}
      )
      session.register_tool("get_weather") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tool_choice"]).to eq({"type" => "function", "function" => {"name" => "get_weather"}})
    end

    it "includes reasoning_effort from reasoning config" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        reasoning: {"effort" => "high"}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["reasoning_effort"]).to eq("high")
    end

    it "maps text format to response_format" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        text: {
          "format" => {
            "type" => "json_schema",
            "json_schema" => {
              "name" => "weather",
              "schema" => {
                "type" => "object",
                "properties" => {
                  "forecast" => {"type" => "string"}
                }
              }
            }
          }
        }
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["response_format"]).to eq({
        "type" => "json_schema",
        "json_schema" => {
          "name" => "weather",
          "schema" => {
            "type" => "object",
            "properties" => {
              "forecast" => {"type" => "string"}
            }
          }
        }
      })
    end

    it "reshapes Open Responses canonical text.format json_schema into Chat Completions response_format" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        text: {
          "format" => {
            "type" => "json_schema",
            "name" => "Person",
            "schema" => {"type" => "object"},
            "strict" => true,
            "description" => "A person"
          }
        }
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["response_format"]).to eq({
        "type" => "json_schema",
        "json_schema" => {
          "name" => "Person",
          "schema" => {"type" => "object"},
          "strict" => true,
          "description" => "A person"
        }
      })
    end

    it "passes through json_object response_format unchanged" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        text: {"format" => {"type" => "json_object"}}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["response_format"]).to eq({"type" => "json_object"})
    end

    it "sets logprobs when top_logprobs is requested" do
      session = PromptBuilder::Session.new(model: "gpt-4o", top_logprobs: 5)
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["logprobs"]).to be true
      expect(h["top_logprobs"]).to eq(5)
    end

    it "serializes assistant text content as chat content parts" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [
          PromptBuilder::Content::OutputText.new(text: "Part 1"),
          PromptBuilder::Content::OutputText.new(text: "Part 2")
        ]
      ))

      h = described_class.request_payload(session)
      expect(h["messages"][0]).to eq({
        "role" => "assistant",
        "content" => [
          {"type" => "text", "text" => "Part 1"},
          {"type" => "text", "text" => "Part 2"}
        ]
      })
    end

    it "includes nil content on assistant tool call messages" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "get_weather", call_id: "call_1", arguments: '{"city":"London"}'
      ))

      h = described_class.request_payload(session)
      expect(h["messages"][0]).to include("role" => "assistant", "content" => nil)
    end

    it "omits unsupported session fields" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        include: ["reasoning.encrypted_content"],
        background: true,
        max_tool_calls: 2,
        truncation: "auto"
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h).not_to have_key("include")
      expect(h).not_to have_key("background")
      expect(h).not_to have_key("max_tool_calls")
      expect(h).not_to have_key("truncation")
    end

    it "passes through prompt_cache_key" do
      session = PromptBuilder::Session.new(model: "gpt-4o", prompt_cache_key: "ck-abc")
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["prompt_cache_key"]).to eq("ck-abc")
    end

    it "passes through prompt_cache_retention" do
      session = PromptBuilder::Session.new(model: "gpt-4o", prompt_cache_retention: "24h")
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["prompt_cache_retention"]).to eq("24h")
    end

    it "passes safety_identifier through directly (not via legacy user)" do
      session = PromptBuilder::Session.new(model: "gpt-4o", safety_identifier: "user-123")
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["safety_identifier"]).to eq("user-123")
      expect(h).not_to have_key("user")
    end

    it "maps text.verbosity to top-level verbosity" do
      session = PromptBuilder::Session.new(model: "gpt-4o", text: {"verbosity" => "low"})
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["verbosity"]).to eq("low")
    end

    it "maps both text.format and text.verbosity together" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        text: {"format" => {"type" => "json_object"}, "verbosity" => "high"}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["response_format"]).to eq({"type" => "json_object"})
      expect(h["verbosity"]).to eq("high")
    end

    it "omits unsupported text config keys while mapping the supported ones" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        text: {
          "format" => {"type" => "json_object"},
          "stop" => "STOP"
        }
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["response_format"]).to eq({"type" => "json_object"})
      expect(h).not_to have_key("stop")
    end

    it "omits unsupported reasoning keys while mapping effort" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        reasoning: {"effort" => "high", "summary" => "detailed"}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["reasoning_effort"]).to eq("high")
      expect(h).not_to have_key("summary")
    end

    it "omits stream_options when stream is not set" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        stream_options: {"include_usage" => true}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h).not_to have_key("stream_options")
    end

    it "omits unsupported stream_options keys" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        stream: true,
        stream_options: {"include_usage" => true, "foo" => "bar"}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["stream_options"]).to eq({"include_usage" => true})
    end

    it "omits assistant image content" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::InputImage.new(url: "https://example.com/img.png")]
      ))

      h = described_class.request_payload(session)
      expect(h["messages"]).to eq([{"role" => "user", "content" => [{"type" => "text", "text" => "Hi"}]}])
    end

    it "drops OutputText annotations silently so a parsed citation can round-trip" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::OutputText.new(text: "Hi", annotations: [{"type" => "citation"}])]
      ))

      h = described_class.request_payload(session)
      expect(h["messages"][0]["content"]).to eq([{"type" => "text", "text" => "Hi"}])
    end

    it "converts array output on FunctionCallOutput to content parts" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Weather?")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "get_weather", call_id: "call_1", arguments: '{"city":"London"}'
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "call_1",
        output: [PromptBuilder::Content::OutputText.new(text: "72F sunny")]
      ))

      h = described_class.request_payload(session)
      tool_msg = h["messages"][2]
      expect(tool_msg["role"]).to eq("tool")
      expect(tool_msg["content"]).to eq([{"type" => "text", "text" => "72F sunny"}])
    end

    it "omits unsupported content types in array output and collapses to an empty string" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "call_1",
        output: [PromptBuilder::Content::InputImage.new(url: "https://example.com/img.png")]
      ))

      h = described_class.request_payload(session)
      tool_msg = h["messages"].last
      expect(tool_msg["role"]).to eq("tool")
      expect(tool_msg["content"]).to eq("")
    end

    it "collapses an empty array output to an empty string" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(call_id: "call_1", output: []))

      h = described_class.request_payload(session)
      expect(h["messages"].last["content"]).to eq("")
    end

    it "omits allowed_tools tool_choice" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        tool_choice: {"type" => "allowed_tools", "tools" => ["search"], "mode" => "auto"}
      )
      session.register_tool("search") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h).not_to have_key("tool_choice")
      expect(h["tools"].length).to eq(1)
    end

    it "passes through optional parameters" do
      session = PromptBuilder::Session.new(
        model: "gpt-4o",
        top_p: 0.9,
        presence_penalty: 0.5,
        frequency_penalty: 0.3,
        top_logprobs: 5,
        store: true,
        metadata: {"key" => "val"},
        service_tier: "default",
        stream: true,
        stream_options: {"include_usage" => true}
      )
      session.register_tool("test") { |_| "ok" }
      session.parallel_tool_calls = true
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["top_p"]).to eq(0.9)
      expect(h["presence_penalty"]).to eq(0.5)
      expect(h["frequency_penalty"]).to eq(0.3)
      expect(h["parallel_tool_calls"]).to be true
      expect(h["logprobs"]).to be true
      expect(h["top_logprobs"]).to eq(5)
      expect(h["store"]).to be true
      expect(h["metadata"]).to eq({"key" => "val"})
      expect(h["service_tier"]).to eq("default")
      expect(h["stream"]).to be true
      expect(h["stream_options"]).to eq({"include_usage" => true})
    end

    it "passes through parallel_tool_calls even when no tools are registered" do
      session = PromptBuilder::Session.new(model: "gpt-4o", parallel_tool_calls: false)
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["parallel_tool_calls"]).to be false
      expect(h).not_to have_key("tools")
    end
  end

  describe ".parse_response" do
    let(:openai_response) do
      {
        "id" => "chatcmpl-123",
        "object" => "chat.completion",
        "created" => 1700000000,
        "model" => "gpt-4o-2024-08-06",
        "choices" => [{
          "index" => 0,
          "message" => {
            "role" => "assistant",
            "content" => "Hello! How can I help?"
          },
          "finish_reason" => "stop"
        }],
        "usage" => {
          "prompt_tokens" => 10,
          "completion_tokens" => 8,
          "total_tokens" => 18
        }
      }
    end

    it "raises an ErrorResponseError for an OpenAI error envelope" do
      expect {
        described_class.parse_response({
          "error" => {
            "message" => "Incorrect API key provided",
            "type" => "invalid_request_error",
            "code" => "invalid_api_key"
          }
        })
      }.to raise_error(PromptBuilder::ErrorResponseError, "the API returned an error: invalid_api_key: Incorrect API key provided")
    end

    it "raises an ErrorResponseError for a string error payload" do
      expect {
        described_class.parse_response({"error" => "model overloaded"})
      }.to raise_error(PromptBuilder::ErrorResponseError, /model overloaded/)
    end

    it "raises an UnexpectedPayloadError for unrecognized payloads" do
      expect {
        described_class.parse_response({"foo" => "bar"})
      }.to raise_error(PromptBuilder::UnexpectedPayloadError, /missing "choices"/)
    end

    it "parses a basic OpenAI response" do
      response = described_class.parse_response(openai_response)
      expect(response.id).to eq("chatcmpl-123")
      expect(response.object).to eq("chat.completion")
      expect(response.created_at).to eq(1700000000)
      expect(response.model).to eq("gpt-4o-2024-08-06")
      expect(response.status).to eq("completed")
      expect(response.text).to eq("Hello! How can I help?")
      expect(response.usage.input_tokens).to eq(10)
      expect(response.usage.output_tokens).to eq(8)
    end

    it "parses a response with tool calls" do
      openai_tc_response = {
        "id" => "chatcmpl-456",
        "object" => "chat.completion",
        "created" => 1700000000,
        "model" => "gpt-4o",
        "choices" => [{
          "index" => 0,
          "message" => {
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [{
              "id" => "call_abc",
              "type" => "function",
              "function" => {
                "name" => "get_weather",
                "arguments" => '{"city":"London"}'
              }
            }]
          },
          "finish_reason" => "tool_calls"
        }],
        "usage" => {"prompt_tokens" => 10, "completion_tokens" => 5}
      }

      response = described_class.parse_response(openai_tc_response)
      expect(response.status).to eq("completed")
      expect(response).to have_tool_calls
      expect(response.tool_calls.length).to eq(1)
      expect(response.tool_calls[0].name).to eq("get_weather")
      expect(response.tool_calls[0].call_id).to eq("call_abc")
      expect(response.tool_calls[0].arguments).to eq('{"city":"London"}')
    end

    it "maps length finish_reason to incomplete" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{"message" => {"content" => "partial"}, "finish_reason" => "length"}]
      })
      expect(response.status).to eq("incomplete")
    end

    it "parses content returned as an array of content blocks" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{
          "message" => {
            "role" => "assistant",
            "content" => [
              {"type" => "text", "text" => "Hello "},
              {"type" => "text", "text" => "world"}
            ]
          },
          "finish_reason" => "stop"
        }]
      })

      expect(response.output.length).to eq(1)
      msg = response.output[0]
      expect(msg).to be_a(PromptBuilder::Items::Message)
      texts = msg.content.map(&:text)
      expect(texts).to eq(["Hello ", "world"])
    end

    it "omits the assistant message when content is an empty string" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{
          "message" => {"role" => "assistant", "content" => "", "tool_calls" => [
            {"id" => "call_1", "type" => "function", "function" => {"name" => "f", "arguments" => "{}"}}
          ]},
          "finish_reason" => "tool_calls"
        }]
      })

      expect(response.output.length).to eq(1)
      expect(response.output.first).to be_a(PromptBuilder::Items::FunctionCall)
    end

    it "maps content_filter to failed" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{"message" => {"content" => ""}, "finish_reason" => "content_filter"}]
      })
      expect(response.status).to eq("failed")
    end

    it "can be added to a session" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hello")

      response = described_class.parse_response(openai_response)
      session.add_response(response)

      expect(session.items.length).to eq(2)
      expect(session.items[1].role).to eq("assistant")
    end

    it "parses a refusal response into a RefusalContent message" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{
          "message" => {"role" => "assistant", "content" => nil, "refusal" => "I cannot help with that."},
          "finish_reason" => "stop"
        }]
      })

      expect(response.output.length).to eq(1)
      msg = response.output[0]
      expect(msg).to be_a(PromptBuilder::Items::Message)
      expect(msg.role).to eq("assistant")
      expect(msg.content[0]).to be_a(PromptBuilder::Content::RefusalContent)
      expect(msg.content[0].refusal).to eq("I cannot help with that.")
    end

    it "parses logprobs into OutputText" do
      logprob_data = [{"token" => "Hello", "logprob" => -0.5, "bytes" => [72], "top_logprobs" => []}]

      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{
          "message" => {"role" => "assistant", "content" => "Hello"},
          "logprobs" => {"content" => logprob_data},
          "finish_reason" => "stop"
        }]
      })

      msg = response.output[0]
      expect(msg.content[0]).to be_a(PromptBuilder::Content::OutputText)
      expect(msg.content[0].logprobs).to eq(logprob_data)
    end

    it "copies message.annotations onto OutputText (string content form)" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{
          "message" => {
            "role" => "assistant",
            "content" => "See [example.com](https://example.com)",
            "annotations" => [
              {"type" => "url_citation",
               "url_citation" => {"url" => "https://example.com", "title" => "Example"}}
            ]
          },
          "finish_reason" => "stop"
        }]
      })

      out = response.output[0].content[0]
      expect(out).to be_a(PromptBuilder::Content::OutputText)
      expect(out.annotations.length).to eq(1)
      expect(out.annotations[0]["type"]).to eq("url_citation")
    end

    it "copies message.annotations onto OutputText (array content form)" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{
          "message" => {
            "role" => "assistant",
            "content" => [{"type" => "text", "text" => "Hi"}],
            "annotations" => [{"type" => "url_citation"}]
          },
          "finish_reason" => "stop"
        }]
      })

      out = response.output[0].content[0]
      expect(out.annotations).to eq([{"type" => "url_citation"}])
    end

    it "attaches message.annotations and logprobs to only the first text block" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{
          "message" => {
            "role" => "assistant",
            "content" => [
              {"type" => "text", "text" => "First"},
              {"type" => "text", "text" => "Second"}
            ],
            "annotations" => [{"type" => "url_citation"}]
          },
          "logprobs" => {"content" => [{"token" => "First", "logprob" => -0.1}]},
          "finish_reason" => "stop"
        }]
      })

      contents = response.output[0].content
      expect(contents[0].annotations).to eq([{"type" => "url_citation"}])
      expect(contents[0].logprobs).to eq([{"token" => "First", "logprob" => -0.1}])
      expect(contents[1].annotations).to eq([])
      expect(contents[1].logprobs).to eq([])
    end

    it "round-trips an assistant message with annotations through request_payload" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{
          "message" => {
            "role" => "assistant",
            "content" => "Hi",
            "annotations" => [{"type" => "url_citation"}]
          },
          "finish_reason" => "stop"
        }]
      })

      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hello")
      session.add_response(response)
      session.user("Follow-up")

      h = described_class.request_payload(session)
      assistant_msg = h["messages"].find { |m| m["role"] == "assistant" }
      expect(assistant_msg["content"]).to eq([{"type" => "text", "text" => "Hi"}])
    end

    it "populates service_tier from the response" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "service_tier" => "default",
        "choices" => [{"message" => {"content" => "Hi"}, "finish_reason" => "stop"}]
      })

      expect(response.service_tier).to eq("default")
    end

    it "captures system_fingerprint in extra" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "system_fingerprint" => "fp_abc",
        "choices" => [{"message" => {"content" => "Hi"}, "finish_reason" => "stop"}]
      })

      expect(response.extra).to eq({"system_fingerprint" => "fp_abc"})
    end

    it "raises for streaming chunks" do
      expect {
        described_class.parse_response({"object" => "chat.completion.chunk", "choices" => []})
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /streaming chunks/)
    end

    it "parses only the first choice when multiple are present" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [
          {"message" => {"content" => "One"}, "finish_reason" => "stop"},
          {"message" => {"content" => "Two"}, "finish_reason" => "stop"}
        ]
      })

      expect(response.output.length).to eq(1)
      expect(response.output[0].content[0].text).to eq("One")
    end

    it "skips unsupported response content block types" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{
          "message" => {"content" => [
            {"type" => "input_audio", "input_audio" => {}},
            {"type" => "text", "text" => "Hi"}
          ]},
          "finish_reason" => "stop"
        }]
      })

      expect(response.output[0].content.length).to eq(1)
      expect(response.output[0].content[0].text).to eq("Hi")
    end

    it "skips custom (non-function) tool calls" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{
          "message" => {"content" => nil, "tool_calls" => [{"id" => "call_1", "type" => "custom"}]},
          "finish_reason" => "tool_calls"
        }]
      })

      expect(response.output).to eq([])
    end

    it "ignores audio responses" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{
          "message" => {"content" => nil, "audio" => {"id" => "audio_1"}},
          "finish_reason" => "stop"
        }]
      })

      expect(response.output).to eq([])
    end

    it "maps the legacy function_call finish_reason to completed" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{"message" => {"content" => "Hi"}, "finish_reason" => "function_call"}]
      })
      expect(response.status).to eq("completed")
    end

    it "parses prompt_tokens_details and completion_tokens_details into usage" do
      response = described_class.parse_response({
        "model" => "gpt-4o",
        "choices" => [{"message" => {"content" => "Hi"}, "finish_reason" => "stop"}],
        "usage" => {
          "prompt_tokens" => 10,
          "completion_tokens" => 5,
          "total_tokens" => 15,
          "prompt_tokens_details" => {"cached_tokens" => 4, "audio_tokens" => 0},
          "completion_tokens_details" => {"reasoning_tokens" => 2, "audio_tokens" => 0}
        }
      })

      expect(response.usage.input_tokens).to eq(10)
      expect(response.usage.output_tokens).to eq(5)
      expect(response.usage.total_tokens).to eq(15)
      expect(response.usage.input_tokens_details).to eq({"cached_tokens" => 4, "audio_tokens" => 0})
      expect(response.usage.output_tokens_details).to eq({"reasoning_tokens" => 2, "audio_tokens" => 0})
      expect(response.usage.cached_tokens).to eq(4)
      expect(response.usage.reasoning_tokens).to eq(2)
    end
  end

  describe "session helpers" do
    it "serializes Session#json_output to response_format" do
      schema = {"type" => "object", "properties" => {"answer" => {"type" => "string"}}}
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hi")
      session.json_output(schema, name: "reply", strict: true)

      h = described_class.request_payload(session)
      expect(h["response_format"]).to eq({
        "type" => "json_schema",
        "json_schema" => {"name" => "reply", "schema" => schema, "strict" => true}
      })
    end

    it "serializes Session#think effort to reasoning_effort" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hi")
      session.think(effort: :medium)

      h = described_class.request_payload(session)
      expect(h["reasoning_effort"]).to eq("medium")
    end

    it "omits reasoning when Session#think sets only budget_tokens" do
      session = PromptBuilder::Session.new(model: "gpt-4o")
      session.user("Hi")
      session.think(budget_tokens: 8_000)

      h = described_class.request_payload(session)
      expect(h).not_to have_key("reasoning_effort")
    end
  end
end
