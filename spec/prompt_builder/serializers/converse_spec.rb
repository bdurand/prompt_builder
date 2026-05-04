# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Serializers::Converse do
  before { PromptBuilder.reset_tool_registry! }

  describe ".request_payload" do
    it "converts a session to Converse format" do
      session = PromptBuilder::Session.new(
        model: "amazon.nova-pro-v1:0",
        instructions: "You are helpful.",
        temperature: 0.7,
        max_output_tokens: 1024
      )
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["modelId"]).to eq("amazon.nova-pro-v1:0")
      expect(h["system"]).to eq([{"text" => "You are helpful."}])
      expect(h["inferenceConfig"]).to eq({"maxTokens" => 1024, "temperature" => 0.7})
      expect(h["messages"].length).to eq(1)
      expect(h["messages"][0]["role"]).to eq("user")
      expect(h["messages"][0]["content"]).to eq([{"text" => "Hello"}])
    end

    it "raises for server state mode sessions" do
      session = PromptBuilder::Session.new(previous_response_id: "resp_1")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::InvalidStateError)
    end

    it "omits inferenceConfig when no inference fields are set" do
      session = PromptBuilder::Session.new(model: "amazon.nova-lite-v1:0")
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["inferenceConfig"]).to be_nil
    end

    it "includes topP in inferenceConfig" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0", top_p: 0.9)
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["inferenceConfig"]["topP"]).to eq(0.9)
    end

    it "merges system and developer messages into top-level system" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0", instructions: "Base instruction")
      session.system("Extra system context")
      session.developer("Developer note")
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["system"].length).to eq(3)
      expect(h["system"][0]["text"]).to eq("Base instruction")
      expect(h["system"][1]["text"]).to eq("Extra system context")
      expect(h["system"][2]["text"]).to eq("Developer note")
      expect(h["messages"].length).to eq(1)
    end

    it "omits system when no system messages are present" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["system"]).to be_nil
    end

    it "maps assistant role correctly" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("Hello")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::OutputText.new(text: "Hi there")]
      ))

      h = described_class.request_payload(session)
      expect(h["messages"][1]["role"]).to eq("assistant")
      expect(h["messages"][1]["content"]).to eq([{"text" => "Hi there"}])
    end

    it "merges consecutive same-role messages" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("First")
      session.user("Second")

      h = described_class.request_payload(session)
      expect(h["messages"].length).to eq(1)
      expect(h["messages"][0]["content"].length).to eq(2)
      expect(h["messages"][0]["content"][0]["text"]).to eq("First")
      expect(h["messages"][0]["content"][1]["text"]).to eq("Second")
    end

    it "converts tool definitions to toolSpec format" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.register_tool(
        "get_weather",
        description: "Get current weather",
        parameters: {"type" => "object", "properties" => {"city" => {"type" => "string"}}}
      ) { |_| "sunny" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["toolConfig"]["tools"].length).to eq(1)
      tool = h["toolConfig"]["tools"][0]["toolSpec"]
      expect(tool["name"]).to eq("get_weather")
      expect(tool["description"]).to eq("Get current weather")
      expect(tool["inputSchema"]["json"]).to eq({
        "type" => "object",
        "properties" => {"city" => {"type" => "string"}}
      })
    end

    it "defaults tool inputSchema to empty object when no parameters" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.register_tool("ping") { |_| "pong" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["toolConfig"]["tools"][0]["toolSpec"]["inputSchema"]["json"]).to eq({
        "type" => "object", "properties" => {}
      })
    end

    it "converts FunctionCall items to toolUse content blocks" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("What's the weather?")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "get_weather", call_id: "tooluse_abc", arguments: '{"city":"London"}'
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "tooluse_abc", output: "72F and sunny"
      ))

      h = described_class.request_payload(session)
      messages = h["messages"]
      expect(messages.length).to eq(3)

      assistant_msg = messages[1]
      expect(assistant_msg["role"]).to eq("assistant")
      tool_use = assistant_msg["content"][0]["toolUse"]
      expect(tool_use["toolUseId"]).to eq("tooluse_abc")
      expect(tool_use["name"]).to eq("get_weather")
      expect(tool_use["input"]).to eq({"city" => "London"})

      user_msg = messages[2]
      expect(user_msg["role"]).to eq("user")
      tool_result = user_msg["content"][0]["toolResult"]
      expect(tool_result["toolUseId"]).to eq("tooluse_abc")
      expect(tool_result["content"]).to eq([{"text" => "72F and sunny"}])
    end

    it "converts array output on FunctionCallOutput to content blocks in toolResult" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("Weather?")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "get_weather", call_id: "tooluse_1", arguments: "{}"
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "tooluse_1",
        output: [PromptBuilder::Content::InputText.new(text: "Sunny and warm")]
      ))

      h = described_class.request_payload(session)
      tool_result = h["messages"][2]["content"][0]["toolResult"]
      expect(tool_result["content"]).to eq([{"text" => "Sunny and warm"}])
    end

    it "includes status on toolResult when present on FunctionCallOutput" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "ping", call_id: "call_1", arguments: "{}"
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "call_1", output: "error occurred", status: "error"
      ))

      h = described_class.request_payload(session)
      tool_result = h["messages"][2]["content"][0]["toolResult"]
      expect(tool_result["status"]).to eq("error")
    end

    it "maps Open Responses status values to Bedrock toolResult status" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "ping", call_id: "call_1", arguments: "{}"
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "call_1", output: "fine", status: "completed"
      ))

      h = described_class.request_payload(session)
      tool_result = h["messages"][2]["content"][0]["toolResult"]
      expect(tool_result["status"]).to eq("success")
    end

    it "always emits a non-empty toolResult content array even when output is nil" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "ping", call_id: "call_1", arguments: "{}"
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "call_1", output: nil
      ))

      h = described_class.request_payload(session)
      tool_result = h["messages"][2]["content"][0]["toolResult"]
      expect(tool_result["content"]).to eq([{"text" => ""}])
    end

    it "converts InputImage with base64 data" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(data: "abc123", media_type: "image/png")]
      ))

      h = described_class.request_payload(session)
      image = h["messages"][0]["content"][0]["image"]
      expect(image["format"]).to eq("png")
      expect(image["source"]).to eq({"bytes" => "abc123"})
    end

    it "converts InputImage with S3 URI" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(
          image_url: "s3://my-bucket/images/photo.jpeg",
          media_type: "image/jpeg"
        )]
      ))

      h = described_class.request_payload(session)
      image = h["messages"][0]["content"][0]["image"]
      expect(image["format"]).to eq("jpeg")
      expect(image["source"]).to eq({"s3Location" => {"uri" => "s3://my-bucket/images/photo.jpeg"}})
    end

    it "detects image format from URL extension when media_type is absent" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(
          image_url: "s3://my-bucket/images/photo.webp"
        )]
      ))

      h = described_class.request_payload(session)
      expect(h["messages"][0]["content"][0]["image"]["format"]).to eq("webp")
    end

    it "converts InputFile with base64 data" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_data: "pdfbytes", filename: "report.pdf")]
      ))

      h = described_class.request_payload(session)
      document = h["messages"][0]["content"][0]["document"]
      expect(document["format"]).to eq("pdf")
      expect(document["name"]).to eq("report")
      expect(document["source"]).to eq({"bytes" => "pdfbytes"})
    end

    it "converts InputFile with S3 URI" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(
          file_url: "s3://my-bucket/docs/report.pdf",
          filename: "report.pdf"
        )]
      ))

      h = described_class.request_payload(session)
      document = h["messages"][0]["content"][0]["document"]
      expect(document["format"]).to eq("pdf")
      expect(document["name"]).to eq("report")
      expect(document["source"]).to eq({"s3Location" => {"uri" => "s3://my-bucket/docs/report.pdf"}})
    end

    it "sanitizes document name to match Bedrock's allowed character set" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_data: "x", filename: "my_report.v2.pdf")]
      ))

      h = described_class.request_payload(session)
      document = h["messages"][0]["content"][0]["document"]
      expect(document["name"]).to eq("my-report-v2")
    end

    it "raises for Compaction items" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Compaction.new(encrypted_content: "abc"))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /Compaction/)
    end

    it "raises for ItemReference items" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::ItemReference.new(id: "msg_1"))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /ItemReference/)
    end

    it "detects document format and name from file_url extension when no filename is set" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_url: "s3://my-bucket/data.csv")]
      ))

      h = described_class.request_payload(session)
      document = h["messages"][0]["content"][0]["document"]
      expect(document["format"]).to eq("csv")
      expect(document["name"]).to eq("data")
    end

    it "derives distinct document names from file_url basenames for multiple unnamed documents" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [
          PromptBuilder::Content::InputFile.new(file_url: "s3://bucket/q1.pdf"),
          PromptBuilder::Content::InputFile.new(file_url: "s3://bucket/q2.pdf")
        ]
      ))

      h = described_class.request_payload(session)
      names = h["messages"][0]["content"].map { |c| c["document"]["name"] }
      expect(names).to eq(["q1", "q2"])
    end

    it "converts InputVideo with S3 URI" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputVideo.new(video_url: "s3://my-bucket/videos/clip.mp4")]
      ))

      h = described_class.request_payload(session)
      video = h["messages"][0]["content"][0]["video"]
      expect(video["format"]).to eq("mp4")
      expect(video["source"]).to eq({"s3Location" => {"uri" => "s3://my-bucket/videos/clip.mp4"}})
    end

    it "converts tool_choice 'auto' to Converse format" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0", tool_choice: "auto")
      session.register_tool("search") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["toolConfig"]["toolChoice"]).to eq({"auto" => {}})
    end

    it "converts tool_choice 'required' to any" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0", tool_choice: "required")
      session.register_tool("search") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["toolConfig"]["toolChoice"]).to eq({"any" => {}})
    end

    it "converts specific function tool_choice" do
      session = PromptBuilder::Session.new(
        model: "amazon.nova-pro-v1:0",
        tool_choice: {"type" => "function", "name" => "get_weather"}
      )
      session.register_tool("get_weather") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["toolConfig"]["toolChoice"]).to eq({"tool" => {"name" => "get_weather"}})
    end

    it "accepts the nested OpenAI tool_choice shape" do
      session = PromptBuilder::Session.new(
        model: "amazon.nova-pro-v1:0",
        tool_choice: {"type" => "function", "function" => {"name" => "get_weather"}}
      )
      session.register_tool("get_weather") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["toolConfig"]["toolChoice"]).to eq({"tool" => {"name" => "get_weather"}})
    end

    it "omits toolConfig when no tools and no tool_choice" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["toolConfig"]).to be_nil
    end

    it "raises for unsupported session fields" do
      session = PromptBuilder::Session.new(
        model: "amazon.nova-pro-v1:0",
        presence_penalty: 0.5,
        frequency_penalty: 0.2
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /presence_penalty/)
    end

    it "raises for stream field" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0", stream: true)
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /stream/)
    end

    it "raises for metadata field" do
      session = PromptBuilder::Session.new(
        model: "amazon.nova-pro-v1:0",
        metadata: {"user_id" => "123"}
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /metadata/)
    end

    it "raises for text (response format) field" do
      session = PromptBuilder::Session.new(
        model: "amazon.nova-pro-v1:0",
        text: {"format" => {"type" => "json_object"}}
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /text/)
    end

    it "raises for reasoning field" do
      session = PromptBuilder::Session.new(
        model: "amazon.nova-pro-v1:0",
        reasoning: {"budget_tokens" => 1024}
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /reasoning/)
    end

    it "raises for parallel_tool_calls field" do
      session = PromptBuilder::Session.new(
        model: "amazon.nova-pro-v1:0",
        parallel_tool_calls: false
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /parallel_tool_calls/)
    end

    it "raises for Reasoning items" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("Think hard")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        content: [{"type" => "thinking", "thinking" => "Let me think..."}]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /Reasoning/)
    end

    it "drops RefusalContent silently so a parsed refusal can stay in session history" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("Hello")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::RefusalContent.new(refusal: "I cannot help.")]
      ))
      session.user("Try again")

      h = described_class.request_payload(session)
      # The refusal-only assistant message is skipped; the two user messages merge.
      expect(h["messages"].map { |m| m["role"] }).to eq(["user"])
    end

    it "raises for InputImage with a non-S3 URL" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(image_url: "https://example.com/photo.png")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /S3 URI/)
    end

    it "raises for InputImage when format cannot be detected" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(data: "abc123")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /image format/)
    end

    it "raises for InputFile with a non-S3 URL" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_url: "https://example.com/report.pdf")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /S3 URI/)
    end

    it "raises for InputVideo with a non-S3 URL" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputVideo.new(video_url: "https://example.com/clip.mp4")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /S3 URI/)
    end

    it "raises for tool_choice 'none'" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0", tool_choice: "none")
      session.register_tool("search") { |_| "ok" }
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /tool_choice 'none'/)
    end

    it "raises for tool_choice without tools" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0", tool_choice: "auto")
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /tool_choice without tools/)
    end

    it "raises for function tool_choice missing name" do
      session = PromptBuilder::Session.new(
        model: "amazon.nova-pro-v1:0",
        tool_choice: {"type" => "function"}
      )
      session.register_tool("search") { |_| "ok" }
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /tool_choice.name/)
    end

    it "raises for assistant InputImage content" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::InputImage.new(data: "abc", media_type: "image/png")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /assistant InputImage/)
    end
  end

  describe ".parse_response" do
    let(:converse_response) do
      {
        "output" => {
          "message" => {
            "role" => "assistant",
            "content" => [
              {"text" => "Hello! How can I help?"}
            ]
          }
        },
        "stopReason" => "end_turn",
        "usage" => {
          "inputTokens" => 10,
          "outputTokens" => 8,
          "totalTokens" => 18
        }
      }
    end

    it "parses a basic Converse response" do
      response = described_class.parse_response(converse_response)
      expect(response.status).to eq("completed")
      expect(response.text).to eq("Hello! How can I help?")
      expect(response.usage.input_tokens).to eq(10)
      expect(response.usage.output_tokens).to eq(8)
      expect(response.usage.total_tokens).to eq(18)
    end

    it "parses a response with tool use" do
      response = described_class.parse_response({
        "output" => {
          "message" => {
            "role" => "assistant",
            "content" => [
              {"text" => "Let me check the weather."},
              {
                "toolUse" => {
                  "toolUseId" => "tooluse_abc",
                  "name" => "get_weather",
                  "input" => {"city" => "London"}
                }
              }
            ]
          }
        },
        "stopReason" => "tool_use",
        "usage" => {"inputTokens" => 10, "outputTokens" => 15, "totalTokens" => 25}
      })

      expect(response.status).to eq("completed")
      expect(response.text).to eq("Let me check the weather.")
      expect(response).to have_tool_calls
      expect(response.tool_calls.length).to eq(1)
      expect(response.tool_calls[0].name).to eq("get_weather")
      expect(response.tool_calls[0].call_id).to eq("tooluse_abc")
      expect(response.tool_calls[0].parsed_arguments).to eq({"city" => "London"})
    end

    it "parses a response with reasoning content" do
      response = described_class.parse_response({
        "output" => {
          "message" => {
            "role" => "assistant",
            "content" => [
              {
                "reasoningContent" => {
                  "reasoningText" => {"text" => "Let me think through this carefully..."}
                }
              },
              {"text" => "Here is my answer."}
            ]
          }
        },
        "stopReason" => "end_turn",
        "usage" => {"inputTokens" => 20, "outputTokens" => 30, "totalTokens" => 50}
      })

      expect(response.output.length).to eq(2)
      expect(response.output[0]).to be_a(PromptBuilder::Items::Reasoning)
      expect(response.output[0].content[0]).to eq({
        "type" => "thinking",
        "thinking" => "Let me think through this carefully..."
      })
      expect(response.output[1]).to be_a(PromptBuilder::Items::Message)
      expect(response.text).to eq("Here is my answer.")
    end

    it "maps max_tokens stopReason to incomplete" do
      response = described_class.parse_response({
        "output" => {
          "message" => {
            "role" => "assistant",
            "content" => [{"text" => "partial response"}]
          }
        },
        "stopReason" => "max_tokens",
        "usage" => {"inputTokens" => 10, "outputTokens" => 100, "totalTokens" => 110}
      })

      expect(response.status).to eq("incomplete")
    end

    it "maps stop_sequence stopReason to completed" do
      response = described_class.parse_response({
        "output" => {
          "message" => {
            "role" => "assistant",
            "content" => [{"text" => "done"}]
          }
        },
        "stopReason" => "stop_sequence",
        "usage" => {"inputTokens" => 5, "outputTokens" => 5, "totalTokens" => 10}
      })

      expect(response.status).to eq("completed")
    end

    it "maps guardrail_intervened stopReason to failed" do
      response = described_class.parse_response({
        "output" => {
          "message" => {
            "role" => "assistant",
            "content" => []
          }
        },
        "stopReason" => "guardrail_intervened",
        "usage" => {"inputTokens" => 5, "outputTokens" => 0, "totalTokens" => 5}
      })

      expect(response.status).to eq("failed")
    end

    it "maps content_filtered stopReason to failed" do
      response = described_class.parse_response({
        "output" => {
          "message" => {"role" => "assistant", "content" => []}
        },
        "stopReason" => "content_filtered",
        "usage" => {"inputTokens" => 5, "outputTokens" => 0, "totalTokens" => 5}
      })

      expect(response.status).to eq("failed")
    end

    it "parses cache token usage" do
      response = described_class.parse_response({
        "output" => {
          "message" => {"role" => "assistant", "content" => [{"text" => "Hi"}]}
        },
        "stopReason" => "end_turn",
        "usage" => {
          "inputTokens" => 100,
          "outputTokens" => 10,
          "totalTokens" => 110,
          "cacheReadInputTokens" => 80,
          "cacheWriteInputTokens" => 20
        }
      })

      expect(response.usage.cached_tokens).to eq(80)
      expect(response.usage.cache_creation_input_tokens).to eq(20)
      expect(response.usage.input_tokens_details).to eq({
        "cached_tokens" => 80,
        "cache_creation_input_tokens" => 20
      })
    end

    it "handles a response with no usage" do
      response = described_class.parse_response({
        "output" => {
          "message" => {"role" => "assistant", "content" => [{"text" => "Hi"}]}
        },
        "stopReason" => "end_turn"
      })

      expect(response.usage).to be_nil
      expect(response.status).to eq("completed")
    end

    it "handles a response with empty content" do
      response = described_class.parse_response({
        "output" => {
          "message" => {"role" => "assistant", "content" => []}
        },
        "stopReason" => "end_turn",
        "usage" => {"inputTokens" => 5, "outputTokens" => 0, "totalTokens" => 5}
      })

      expect(response.output).to be_empty
      expect(response.status).to eq("completed")
    end

    it "can be added to a session" do
      session = PromptBuilder::Session.new(model: "amazon.nova-pro-v1:0")
      session.user("Hello")

      response = described_class.parse_response(converse_response)
      session.add_response(response)

      expect(session.items.length).to eq(2)
      expect(session.items[1]).to be_a(PromptBuilder::Items::Message)
      expect(session.items[1].role).to eq("assistant")
    end
  end
end
