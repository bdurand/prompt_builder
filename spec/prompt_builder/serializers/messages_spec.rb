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

    it "raises when there are no user/assistant messages" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514", instructions: "Be helpful")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /at least one user\/assistant message/)
    end

    it "raises when the first message is not from the user" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.assistant("Out of order")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /first message to have role/)
    end

    it "raises when reasoning is enabled without budget_tokens" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        reasoning: {"type" => "enabled"}
      )
      session.user("Hi")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /budget_tokens when thinking is enabled/)
    end

    it "raises when a tool_result includes a document content block" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Read this")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "fetch", call_id: "toolu_1", arguments: "{}"
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "toolu_1",
        output: [PromptBuilder::Content::InputFile.new(file_url: "https://example.com/doc.pdf")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /tool_result.content/)
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

    it "converts InputImage with URL and drops the unsupported detail field" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(image_url: "https://example.com/img.png", detail: "low")]
      ))

      h = described_class.request_payload(session)
      content = h["messages"][0]["content"][0]
      expect(content["type"]).to eq("image")
      expect(content["source"]).to eq({"type" => "url", "url" => "https://example.com/img.png"})
      expect(content).not_to have_key("detail")
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

    it "converts InputFile with base64 data and defaults media_type to application/pdf" do
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

    it "converts InputImage.file_id to a file source (Anthropic Files API)" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(file_id: "file_abc123")]
      ))

      h = described_class.request_payload(session)
      content = h["messages"][0]["content"][0]
      expect(content["type"]).to eq("image")
      expect(content["source"]).to eq({"type" => "file", "file_id" => "file_abc123"})
    end

    it "converts InputFile.file_id to a file source (Anthropic Files API)" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_id: "file_xyz789")]
      ))

      h = described_class.request_payload(session)
      content = h["messages"][0]["content"][0]
      expect(content["type"]).to eq("document")
      expect(content["source"]).to eq({"type" => "file", "file_id" => "file_xyz789"})
    end

    it "raises with a clear message when InputImage has no usable source" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /image_url, InputImage\.data, or InputImage\.file_id/)
    end

    it "raises with a clear message when InputFile has no usable source" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /file_url, InputFile\.file_data, or InputFile\.file_id/)
    end

    it "marks tool_result as is_error when FunctionCallOutput.status is failed" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Run it")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "run", call_id: "toolu_1", arguments: "{}"
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "toolu_1", output: "boom", status: "failed"
      ))

      h = described_class.request_payload(session)
      tool_result = h["messages"][2]["content"][0]
      expect(tool_result["is_error"]).to be true
    end

    it "does not set is_error for completed tool outputs" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Run it")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "run", call_id: "toolu_1", arguments: "{}"
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "toolu_1", output: "ok", status: "completed"
      ))

      h = described_class.request_payload(session)
      expect(h["messages"][2]["content"][0]).not_to have_key("is_error")
    end

    it "honors InputFile.media_type for base64 documents" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_data: "abc123", media_type: "text/plain")]
      ))

      h = described_class.request_payload(session)
      content = h["messages"][0]["content"][0]
      expect(content["source"]["media_type"]).to eq("text/plain")
    end

    it "raises for Compaction items" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Compaction.new(encrypted_content: "abc"))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /Compaction/)
    end

    it "raises for ItemReference items" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::ItemReference.new(id: "msg_1"))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /ItemReference/)
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

    it "accepts the nested OpenAI tool_choice shape" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        tool_choice: {"type" => "function", "function" => {"name" => "get_weather"}}
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

    it "drops the unsupported strict field on tool definitions" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.register_tool("get_weather", strict: true) { |_| "sunny" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tools"][0]).not_to have_key("strict")
      expect(h["tools"][0]["input_schema"]).to eq({"type" => "object", "properties" => {}})
    end

    it "raises for the text session field (no native equivalent in Anthropic)" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        text: {"format" => {"type" => "json_object"}}
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /does not support session fields.*text/)
    end

    it "raises for reasoning.effort (Anthropic uses budget_tokens)" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        reasoning: {"effort" => "high"}
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /reasoning\.effort/)
    end

    it "defaults thinking.type to 'enabled' when only budget_tokens is provided" do
      session = PromptBuilder::Session.new(
        model: "claude-sonnet-4-20250514",
        reasoning: {"budget_tokens" => 2048}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["thinking"]).to eq({
        "budget_tokens" => 2048,
        "type" => "enabled"
      })
    end

    it "raises when serializing a Reasoning item with only summary blocks" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        summary: [{"type" => "summary_text", "text" => "Thinking about it..."}]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /summary blocks/)
    end

    it "raises when a Reasoning item carries summary blocks even alongside content" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        summary: [{"type" => "summary_text", "text" => "Summary"}],
        content: [{"type" => "thinking", "thinking" => "...", "signature" => "sig"}]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /summary blocks/)
    end

    it "drops unsigned thinking blocks rather than raising (cross-provider history)" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        content: [{"type" => "thinking", "thinking" => "from a Gemini turn"}]
      ))
      session.user("Continue")

      h = described_class.request_payload(session)
      # The Reasoning item produces no assistant message; the two user turns merge.
      expect(h["messages"].map { |m| m["role"] }).to eq(["user"])
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
        reasoning: {"budget_tokens" => 2048, "summary" => "detailed"}
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

    it "always emits a content field on tool_result even for empty output" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Run it")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "run", call_id: "toolu_1", arguments: "{}"
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(call_id: "toolu_1", output: nil))

      h = described_class.request_payload(session)
      tool_result = h["messages"][2]["content"][0]
      expect(tool_result["content"]).to eq([{"type" => "text", "text" => ""}])
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

    it "drops RefusalContent silently so a parsed refusal can stay in session history" do
      session = PromptBuilder::Session.new(model: "claude-sonnet-4-20250514")
      session.user("Hello")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::RefusalContent.new(refusal: "I cannot help.")]
      ))
      session.user("Try again")

      h = described_class.request_payload(session)
      # The refusal-only assistant message is skipped; the two user messages
      # are merged into a single user turn.
      expect(h["messages"].map { |m| m["role"] }).to eq(["user"])
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
      # Anthropic reports input_tokens excluding cached/cache-creation; total
      # must include them so it reflects all billed tokens.
      expect(response.usage.total_tokens).to eq(10 + 5 + 100 + 50)
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

    it "maps stop_sequence and pause_turn stop reasons to completed" do
      stop_seq = described_class.parse_response({
        "stop_reason" => "stop_sequence",
        "stop_sequence" => "<<END>>",
        "content" => [{"type" => "text", "text" => "stopped"}]
      })
      expect(stop_seq.status).to eq("completed")
      expect(stop_seq.incomplete_details).to eq({"stop_sequence" => "<<END>>"})

      pause = described_class.parse_response({
        "stop_reason" => "pause_turn",
        "content" => [{"type" => "text", "text" => "pausing"}]
      })
      expect(pause.status).to eq("completed")
    end

    it "maps refusal stop_reason to failed" do
      response = described_class.parse_response({
        "stop_reason" => "refusal",
        "content" => [{"type" => "text", "text" => "I cannot help with that."}]
      })
      expect(response.status).to eq("failed")
    end

    it "parses usage.service_tier and usage.cache_creation breakdown into input_tokens_details" do
      response = described_class.parse_response({
        "id" => "msg_999",
        "type" => "message",
        "stop_reason" => "end_turn",
        "content" => [{"type" => "text", "text" => "ok"}],
        "usage" => {
          "input_tokens" => 5,
          "output_tokens" => 2,
          "cache_creation_input_tokens" => 80,
          "cache_read_input_tokens" => 20,
          "cache_creation" => {"ephemeral_5m_input_tokens" => 60, "ephemeral_1h_input_tokens" => 20},
          "service_tier" => "priority"
        }
      })

      details = response.usage.input_tokens_details
      expect(details["cache_creation_input_tokens"]).to eq(80)
      expect(details["cached_tokens"]).to eq(20)
      expect(details["cache_creation"]).to eq({"ephemeral_5m_input_tokens" => 60, "ephemeral_1h_input_tokens" => 20})
      expect(details["service_tier"]).to eq("priority")
    end

    it "raises on unknown content block types" do
      expect {
        described_class.parse_response({
          "stop_reason" => "end_turn",
          "content" => [{"type" => "mystery_block"}]
        })
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /mystery_block/)
    end

    it "raises with a built-in tool message for server_tool_use blocks" do
      expect {
        described_class.parse_response({
          "stop_reason" => "end_turn",
          "content" => [{"type" => "server_tool_use", "name" => "web_search", "input" => {}}]
        })
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /built-in tools/)
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
