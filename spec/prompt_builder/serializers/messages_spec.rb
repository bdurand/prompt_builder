# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Serializers::Messages do
  before { PromptBuilder.reset_tool_registry! }

  describe ".request_payload" do
    it "converts a session to Anthropic Messages format" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        instructions: "You are helpful.",
        temperature: 0.7,
        max_output_tokens: 1024
      )
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["model"]).to eq("claude-sonnet-4-20250514")
      expect(h["temperature"]).to eq(0.7)
      expect(h["max_tokens"]).to eq(1024)
      expect(h["system"]).to eq([{"type" => "text", "text" => "You are helpful."}])
      expect(h["messages"].length).to eq(1)
      expect(h["messages"][0]["role"]).to eq("user")
      expect(h["messages"][0]["content"]).to eq([{"type" => "text", "text" => "Hello"}])
    end

    it "defaults max_tokens to 4096" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["max_tokens"]).to eq(4096)
    end

    it "raises for server state mode sessions" do
      session = PromptBuilder::Session.new(previous_response_id: "resp_1")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::InvalidStateError)
    end

    it "merges system and developer messages into top-level system" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514", instructions: "Base instruction")
      session.system("Extra system context")
      session.developer("Developer note")
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["system"].length).to eq(3)
      expect(h["system"][0]["text"]).to eq("Base instruction")
      expect(h["system"][1]["text"]).to eq("Extra system context")
      expect(h["system"][2]["text"]).to eq("Developer note")
      # System/developer messages should not appear in messages array
      expect(h["messages"].length).to eq(1)
    end

    it "converts tool definitions" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.register_tool(
        "get_weather",
        description: "Get weather",
        parameters: {"type" => "object", "properties" => {"city" => {"type" => "string"}}}
      ) { |_| "sunny" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tools"].length).to eq(1)
      tool = h["tools"][0]
      expect(tool["name"]).to eq("get_weather")
      expect(tool["description"]).to eq("Get weather")
      expect(tool["input_schema"]).to eq({"type" => "object", "properties" => {"city" => {"type" => "string"}}})
    end

    it "converts function call items to tool_use blocks" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Weather?")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "get_weather", call_id: "toolu_1", arguments: '{"city":"London"}'
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "toolu_1", output: "72F sunny"
      ))

      h = described_class.request_payload(session)
      messages = h["messages"]
      expect(messages.length).to eq(3) # user, assistant+tool_use, user+tool_result

      assistant_msg = messages[1]
      expect(assistant_msg["role"]).to eq("assistant")
      expect(assistant_msg["content"][0]["type"]).to eq("tool_use")
      expect(assistant_msg["content"][0]["id"]).to eq("toolu_1")
      expect(assistant_msg["content"][0]["name"]).to eq("get_weather")
      expect(assistant_msg["content"][0]["input"]).to eq({"city" => "London"})

      tool_result_msg = messages[2]
      expect(tool_result_msg["role"]).to eq("user")
      expect(tool_result_msg["content"][0]["type"]).to eq("tool_result")
      expect(tool_result_msg["content"][0]["tool_use_id"]).to eq("toolu_1")
    end

    it "merges consecutive same-role messages" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("First")
      session.user("Second")

      h = described_class.request_payload(session)
      expect(h["messages"].length).to eq(1)
      expect(h["messages"][0]["content"].length).to eq(2)
      expect(h["messages"][0]["content"][0]["text"]).to eq("First")
      expect(h["messages"][0]["content"][1]["text"]).to eq("Second")
    end

    it "serializes Anthropic thinking blocks with signatures" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Think hard")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        content: [{"type" => "thinking", "thinking" => "Let me think...", "signature" => "sig_123"}]
      ))

      h = described_class.request_payload(session)
      messages = h["messages"]
      expect(messages.length).to eq(2)
      expect(messages[1]["role"]).to eq("assistant")
      expect(messages[1]["content"][0]["type"]).to eq("thinking")
      expect(messages[1]["content"][0]["thinking"]).to eq("Let me think...")
      expect(messages[1]["content"][0]["signature"]).to eq("sig_123")
    end

    it "converts InputImage with URL" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(image_url: "https://example.com/img.png", detail: "low")]
      ))

      h = described_class.request_payload(session)
      content = h["messages"][0]["content"][0]
      expect(content["type"]).to eq("image")
      expect(content["source"]).to eq({"type" => "url", "url" => "https://example.com/img.png"})
      expect(content["detail"]).to eq("low")
    end

    it "converts InputImage with base64 data" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(data: "abc123", media_type: "image/png")]
      ))

      h = described_class.request_payload(session)
      content = h["messages"][0]["content"][0]
      expect(content["type"]).to eq("image")
      expect(content["source"]).to eq({
        "type" => "base64",
        "media_type" => "image/png",
        "data" => "abc123"
      })
    end

    it "converts InputFile with URL" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_url: "https://example.com/doc.pdf")]
      ))

      h = described_class.request_payload(session)
      content = h["messages"][0]["content"][0]
      expect(content["type"]).to eq("document")
      expect(content["source"]).to eq({"type" => "url", "url" => "https://example.com/doc.pdf"})
    end

    it "converts InputFile with base64 data" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_data: "abc123")]
      ))

      h = described_class.request_payload(session)
      content = h["messages"][0]["content"][0]
      expect(content["type"]).to eq("document")
      expect(content["source"]).to eq({
        "type" => "base64",
        "media_type" => "application/pdf",
        "data" => "abc123"
      })
    end

    it "converts tool_choice 'auto' to hash" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514", tool_choice: "auto")
      session.register_tool("test") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tool_choice"]).to eq({"type" => "auto"})
    end

    it "converts tool_choice 'required' to any" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514", tool_choice: "required")
      session.register_tool("test") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tool_choice"]).to eq({"type" => "any"})
    end

    it "converts specific function tool_choice" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        tool_choice: {"type" => "function", "name" => "get_weather"}
      )
      session.register_tool("get_weather") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tool_choice"]).to eq({"type" => "tool", "name" => "get_weather"})
    end

    it "passes through optional parameters" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        top_p: 0.9,
        metadata: {"user_id" => "123"},
        service_tier: "auto",
        stream: true
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["top_p"]).to eq(0.9)
      expect(h["metadata"]).to eq({"user_id" => "123"})
      expect(h["service_tier"]).to eq("auto")
      expect(h["stream"]).to be true
    end

    it "includes strict on tool definitions" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.register_tool("get_weather", strict: true) { |_| "sunny" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tools"][0]["strict"]).to be true
      expect(h["tools"][0]["input_schema"]).to eq({"type" => "object", "properties" => {}})
    end

    it "maps text and reasoning config to output_config" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        text: {
          "format" => {
            "type" => "json_schema",
            "schema" => {
              "type" => "object",
              "properties" => {
                "forecast" => {"type" => "string"}
              }
            }
          }
        },
        reasoning: {"effort" => "high"}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["output_config"]).to eq({
        "effort" => "high",
        "format" => {
          "type" => "json_schema",
          "schema" => {
            "type" => "object",
            "properties" => {
              "forecast" => {"type" => "string"}
            }
          }
        }
      })
    end

    it "maps reasoning thinking config to top-level thinking" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        reasoning: {
          "type" => "enabled",
          "budget_tokens" => 2048,
          "display" => "omitted"
        }
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["thinking"]).to eq({
        "type" => "enabled",
        "budget_tokens" => 2048,
        "display" => "omitted"
      })
    end

    it "maps parallel_tool_calls to disable_parallel_tool_use" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        parallel_tool_calls: false
      )
      session.register_tool("get_weather") { |_| "sunny" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tool_choice"]).to eq({
        "type" => "auto",
        "disable_parallel_tool_use" => true
      })
    end

    it "raises for unsupported session fields" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        include: ["foo"],
        presence_penalty: 0.1,
        stream_options: {"include_usage" => true}
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /include/)
    end

    it "raises when metadata includes unsupported keys" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        metadata: {"user_id" => "123", "team" => "ops"}
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /metadata\.team/)
    end

    it "raises when reasoning includes unsupported keys" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        reasoning: {"effort" => "high", "summary" => "detailed"}
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /reasoning\.summary/)
    end

    it "raises when thinking is combined with forced tool_choice" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        tool_choice: "required",
        reasoning: {"type" => "enabled", "budget_tokens" => 2048}
      )
      session.register_tool("get_weather") { |_| "sunny" }
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /forced tool_choice/)
    end

    it "raises when parallel_tool_calls are set without tools" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        parallel_tool_calls: false
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /parallel_tool_calls/)
    end

    it "converts array output on FunctionCallOutput to content blocks in tool_result" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Weather?")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "get_weather", call_id: "toolu_1", arguments: '{"city":"London"}'
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "toolu_1",
        output: [PromptBuilder::Content::InputText.new(text: "72F sunny")]
      ))

      h = described_class.request_payload(session)
      tool_result = h["messages"][2]["content"][0]
      expect(tool_result["type"]).to eq("tool_result")
      expect(tool_result["tool_use_id"]).to eq("toolu_1")
      expect(tool_result["content"]).to eq([{"type" => "text", "text" => "72F sunny"}])
    end

    it "raises for allowed_tools tool_choice" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        tool_choice: {"type" => "allowed_tools", "tools" => ["search"], "mode" => "auto"}
      )
      session.register_tool("search") { |_| "ok" }
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /tool_choice\.type.*allowed_tools/)
    end

    it "raises for InputVideo content" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputVideo.new(video_url: "https://example.com/video.mp4")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /InputVideo/)
    end

    it "raises for RefusalContent" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::RefusalContent.new(refusal: "I cannot help.")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /RefusalContent/)
    end
  end

  describe ".parse_response" do
    let(:anthropic_response) do
      {
        "id" => "msg_123",
        "type" => "message",
        "model" => "claude-sonnet-4-20250514",
        "stop_reason" => "end_turn",
        "content" => [
          {"type" => "text", "text" => "Hello! How can I help?"}
        ],
        "usage" => {
          "input_tokens" => 10,
          "output_tokens" => 8
        }
      }
    end

    it "parses a basic Anthropic response" do
      response = described_class.parse_response(anthropic_response)
      expect(response.id).to eq("msg_123")
      expect(response.object).to eq("message")
      expect(response.model).to eq("claude-sonnet-4-20250514")
      expect(response.status).to eq("completed")
      expect(response.text).to eq("Hello! How can I help?")
      expect(response.usage.input_tokens).to eq(10)
      expect(response.usage.output_tokens).to eq(8)
    end

    it "parses cache token usage" do
      response = described_class.parse_response({
        "id" => "msg_123",
        "type" => "message",
        "stop_reason" => "end_turn",
        "content" => [],
        "usage" => {
          "input_tokens" => 10,
          "output_tokens" => 5,
          "cache_creation_input_tokens" => 100,
          "cache_read_input_tokens" => 50
        }
      })
      expect(response.usage.cache_creation_input_tokens).to eq(100)
      expect(response.usage.cached_tokens).to eq(50)
      expect(response.usage.input_tokens_details).to eq({
        "cache_creation_input_tokens" => 100,
        "cached_tokens" => 50
      })
    end

    it "parses a response with tool use" do
      anthropic_tc_response = {
        "id" => "msg_456",
        "type" => "message",
        "model" => "claude-sonnet-4-20250514",
        "stop_reason" => "tool_use",
        "content" => [
          {"type" => "text", "text" => "Let me check the weather."},
          {
            "type" => "tool_use",
            "id" => "toolu_abc",
            "name" => "get_weather",
            "input" => {"city" => "London"}
          }
        ],
        "usage" => {"input_tokens" => 10, "output_tokens" => 15}
      }

      response = described_class.parse_response(anthropic_tc_response)
      expect(response.status).to eq("completed")
      expect(response.text).to eq("Let me check the weather.")
      expect(response).to have_tool_calls
      expect(response.tool_calls.length).to eq(1)
      expect(response.tool_calls[0].name).to eq("get_weather")
      expect(response.tool_calls[0].call_id).to eq("toolu_abc")
      expect(response.tool_calls[0].parsed_arguments).to eq({"city" => "London"})
    end

    it "parses a response with thinking" do
      anthropic_thinking_response = {
        "id" => "msg_789",
        "type" => "message",
        "stop_reason" => "end_turn",
        "content" => [
          {"type" => "thinking", "thinking" => "Let me think about this...", "signature" => "sig_456"},
          {"type" => "text", "text" => "Here's my answer."}
        ],
        "usage" => {"input_tokens" => 10, "output_tokens" => 20}
      }

      response = described_class.parse_response(anthropic_thinking_response)
      expect(response.output.length).to eq(2)
      expect(response.output[0]).to be_a(PromptBuilder::Items::Reasoning)
      expect(response.output[0].content[0]).to eq({
        "type" => "thinking",
        "thinking" => "Let me think about this...",
        "signature" => "sig_456"
      })
      expect(response.output[1]).to be_a(PromptBuilder::Items::Message)
      expect(response.text).to eq("Here's my answer.")
    end

    it "parses a response with redacted thinking" do
      response = described_class.parse_response({
        "id" => "msg_790",
        "type" => "message",
        "stop_reason" => "end_turn",
        "content" => [
          {"type" => "redacted_thinking", "data" => "encrypted"},
          {"type" => "text", "text" => "Final answer"}
        ]
      })

      expect(response.output[0]).to be_a(PromptBuilder::Items::Reasoning)
      expect(response.output[0].content).to eq([
        {"type" => "redacted_thinking", "data" => "encrypted"}
      ])
      expect(response.text).to eq("Final answer")
    end

    it "maps max_tokens stop_reason to incomplete" do
      response = described_class.parse_response({
        "stop_reason" => "max_tokens",
        "content" => [{"type" => "text", "text" => "partial"}],
        "usage" => {"input_tokens" => 10, "output_tokens" => 100}
      })
      expect(response.status).to eq("incomplete")
    end

    it "can be added to a session" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Hello")

      response = described_class.parse_response(anthropic_response)
      session.add_response(response)

      expect(session.items.length).to eq(2)
      expect(session.items[1]).to be_a(PromptBuilder::Items::Message)
      expect(session.items[1].role).to eq("assistant")
    end

    it "parses input_tokens_details and output_tokens_details from usage" do
      response = described_class.parse_response({
        "id" => "msg_123",
        "type" => "message",
        "stop_reason" => "end_turn",
        "content" => [{"type" => "text", "text" => "Hi"}],
        "usage" => {
          "input_tokens" => 10,
          "output_tokens" => 5,
          "input_tokens_details" => {"cached_tokens" => 3},
          "output_tokens_details" => {"reasoning_tokens" => 1}
        }
      })

      expect(response.usage.input_tokens_details).to eq({"cached_tokens" => 3})
      expect(response.usage.output_tokens_details).to eq({"reasoning_tokens" => 1})
      expect(response.usage.cached_tokens).to eq(3)
      expect(response.usage.reasoning_tokens).to eq(1)
    end
  end
end
