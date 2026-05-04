# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Serializers::Gemini do
  before { PromptBuilder.reset_tool_registry! }

  describe ".request_payload" do
    it "converts a session to Gemini format" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        instructions: "You are helpful.",
        temperature: 0.7,
        max_output_tokens: 1024
      )
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["model"]).to eq("gemini-2.0-flash")
      expect(h["generationConfig"]["temperature"]).to eq(0.7)
      expect(h["generationConfig"]["maxOutputTokens"]).to eq(1024)
      expect(h["systemInstruction"]["parts"]).to eq([{"text" => "You are helpful."}])
      expect(h["contents"].length).to eq(1)
      expect(h["contents"][0]["role"]).to eq("user")
      expect(h["contents"][0]["parts"]).to eq([{"text" => "Hello"}])
    end

    it "raises for server state mode sessions" do
      session = PromptBuilder::Session.new(previous_response_id: "resp_1")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::InvalidStateError)
    end

    it "raises when model is missing" do
      session = PromptBuilder::Session.new
      session.user("Hello")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires session.model/)
    end

    it "merges system and developer messages into systemInstruction" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", instructions: "Base instruction")
      session.system("Extra system context")
      session.developer("Developer note")
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["systemInstruction"]["parts"].length).to eq(3)
      expect(h["systemInstruction"]["parts"][0]["text"]).to eq("Base instruction")
      expect(h["systemInstruction"]["parts"][1]["text"]).to eq("Extra system context")
      expect(h["systemInstruction"]["parts"][2]["text"]).to eq("Developer note")
      # System/developer messages should not appear in contents array
      expect(h["contents"].length).to eq(1)
    end

    it "does not include systemInstruction if no system messages" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["systemInstruction"]).to be_nil
    end

    it "converts assistant role to model role" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::OutputText.new(text: "Hi there")]
      ))

      h = described_class.request_payload(session)
      expect(h["contents"][0]["role"]).to eq("model")
      expect(h["contents"][0]["parts"][0]["text"]).to eq("Hi there")
    end

    it "merges consecutive same-role messages" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("First")
      session.user("Second")

      h = described_class.request_payload(session)
      expect(h["contents"].length).to eq(1)
      expect(h["contents"][0]["parts"].length).to eq(2)
      expect(h["contents"][0]["parts"][0]["text"]).to eq("First")
      expect(h["contents"][0]["parts"][1]["text"]).to eq("Second")
    end

    it "converts tool definitions to functionDeclarations" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.register_tool(
        "get_weather",
        description: "Get weather",
        parameters: {"type" => "object", "properties" => {"city" => {"type" => "string"}}}
      ) { |_| "sunny" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tools"].length).to eq(1)
      expect(h["tools"][0]["functionDeclarations"].length).to eq(1)
      func = h["tools"][0]["functionDeclarations"][0]
      expect(func["name"]).to eq("get_weather")
      expect(func["description"]).to eq("Get weather")
      expect(func["parameters"]).to eq({"type" => "object", "properties" => {"city" => {"type" => "string"}}})
    end

    it "converts FunctionCall items to functionCall parts" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Weather?")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "get_weather", call_id: "call_1", arguments: '{"city":"London"}'
      ))

      h = described_class.request_payload(session)
      contents = h["contents"]
      expect(contents.length).to eq(2)

      model_content = contents[1]
      expect(model_content["role"]).to eq("model")
      expect(model_content["parts"][0]["functionCall"]["name"]).to eq("get_weather")
      expect(model_content["parts"][0]["functionCall"]["args"]).to eq({"city" => "London"})
    end

    it "converts FunctionCallOutput items to functionResponse parts" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Weather?")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "get_weather", call_id: "call_1", arguments: '{"city":"London"}'
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "call_1", output: "72F sunny"
      ))

      h = described_class.request_payload(session)
      contents = h["contents"]
      expect(contents.length).to eq(3)

      response_content = contents[2]
      expect(response_content["role"]).to eq("user")
      expect(response_content["parts"][0]["functionResponse"]["name"]).to eq("get_weather")
      expect(response_content["parts"][0]["functionResponse"]["response"]["result"]).to eq("72F sunny")
    end

    it "uses prior FunctionCall name in FunctionCallOutput" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Get info")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "search", call_id: "call_1", arguments: '{"query":"test"}'
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "call_1", output: "found something"
      ))

      h = described_class.request_payload(session)
      response_part = h["contents"][2]["parts"][0]["functionResponse"]
      expect(response_part["name"]).to eq("search")
    end

    it "converts tool_choice auto to AUTO" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", tool_choice: "auto")
      session.register_tool("test") { |_| "result" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["toolConfig"]["functionCallingConfig"]["mode"]).to eq("AUTO")
    end

    it "converts tool_choice none to NONE" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", tool_choice: "none")
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["toolConfig"]["functionCallingConfig"]["mode"]).to eq("NONE")
    end

    it "converts tool_choice required to ANY" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", tool_choice: "required")
      session.register_tool("test") { |_| "result" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["toolConfig"]["functionCallingConfig"]["mode"]).to eq("ANY")
    end

    it "converts function tool_choice to specific allowedFunctionNames" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        tool_choice: {"type" => "function", "name" => "get_weather"}
      )
      session.register_tool("get_weather") { |_| "sunny" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["toolConfig"]["functionCallingConfig"]["mode"]).to eq("ANY")
      expect(h["toolConfig"]["functionCallingConfig"]["allowedFunctionNames"]).to eq(["get_weather"])
    end

    it "accepts the nested OpenAI tool_choice shape" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        tool_choice: {"type" => "function", "function" => {"name" => "get_weather"}}
      )
      session.register_tool("get_weather") { |_| "sunny" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["toolConfig"]["functionCallingConfig"]["allowedFunctionNames"]).to eq(["get_weather"])
    end

    it "includes temperature in generationConfig" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", temperature: 0.5)
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["temperature"]).to eq(0.5)
    end

    it "includes topP in generationConfig" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", top_p: 0.9)
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["topP"]).to eq(0.9)
    end

    it "raises an error for presence_penalty" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", presence_penalty: 0.1)
      session.user("Hi")

      expect { described_class.request_payload(session) }
        .to raise_error(PromptBuilder::UnsupportedFormatError, /presence_penalty/)
    end

    it "raises an error for frequency_penalty" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", frequency_penalty: 0.2)
      session.user("Hi")

      expect { described_class.request_payload(session) }
        .to raise_error(PromptBuilder::UnsupportedFormatError, /frequency_penalty/)
    end

    it "converts text format json_object to responseMimeType" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        text: {"format" => {"type" => "json_object"}}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["responseMimeType"]).to eq("application/json")
      expect(h["generationConfig"]).not_to have_key("responseSchema")
    end

    it "converts text format json_schema to responseMimeType and responseSchema" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        text: {
          "format" => {
            "type" => "json_schema",
            "json_schema" => {
              "name" => "weather",
              "schema" => {
                "type" => "object",
                "properties" => {"forecast" => {"type" => "string"}}
              }
            }
          }
        }
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["responseMimeType"]).to eq("application/json")
      expect(h["generationConfig"]["responseSchema"]).to eq({
        "type" => "object",
        "properties" => {"forecast" => {"type" => "string"}}
      })
    end

    it "supports json_schema format with direct schema key" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        text: {
          "format" => {
            "type" => "json_schema",
            "schema" => {
              "type" => "object",
              "properties" => {"result" => {"type" => "string"}}
            }
          }
        }
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["responseMimeType"]).to eq("application/json")
      expect(h["generationConfig"]["responseSchema"]).to eq({
        "type" => "object",
        "properties" => {"result" => {"type" => "string"}}
      })
    end

    it "includes reasoning budget_tokens in thinkingConfig" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        reasoning: {"budget_tokens" => 5000}
      )
      session.user("Think hard")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["thinkingConfig"]["thinkingBudget"]).to eq(5000)
    end

    it "converts Reasoning items with thinking blocks to thought parts" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Think")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        content: [{"type" => "thinking", "thinking" => "Let me think..."}]
      ))

      h = described_class.request_payload(session)
      contents = h["contents"]
      expect(contents.length).to eq(2)
      expect(contents[1]["role"]).to eq("model")
      expect(contents[1]["parts"][0]["thought"]).to eq(true)
      expect(contents[1]["parts"][0]["text"]).to eq("Let me think...")
    end

    it "converts InputImage with a Google Cloud Storage URL to fileData" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(image_url: "gs://bucket/img.png", media_type: "image/png")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["fileData"]["fileUri"]).to eq("gs://bucket/img.png")
      expect(part["fileData"]["mimeType"]).to eq("image/png")
    end

    it "raises for InputImage with arbitrary public URL" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(image_url: "https://example.com/img.png")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /arbitrary public image URLs/)
    end

    it "converts InputImage with file_id to fileData" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(file_id: "files/abc123", media_type: "image/png")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["fileData"]["fileUri"]).to eq("files/abc123")
      expect(part["fileData"]["mimeType"]).to eq("image/png")
    end

    it "converts InputImage with base64 data to inlineData" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(data: "abc123", media_type: "image/png")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["inlineData"]["data"]).to eq("abc123")
      expect(part["inlineData"]["mimeType"]).to eq("image/png")
    end

    it "raises for InputImage without URL, data, or file_id" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires InputImage\.image_url, InputImage\.data, or InputImage\.file_id/)
    end

    it "raises for InputImage base64 without media_type" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(data: "abc123")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires InputImage.media_type/)
    end

    it "converts InputFile with a gs:// URL to fileData and infers mime from filename" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_url: "gs://bucket/file.pdf")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["fileData"]["fileUri"]).to eq("gs://bucket/file.pdf")
      expect(part["fileData"]["mimeType"]).to eq("application/pdf")
    end

    it "raises for InputFile with arbitrary public URL" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_url: "https://example.com/file.pdf")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /arbitrary public file URLs/)
    end

    it "converts InputFile with base64 data to inlineData using explicit media_type" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_data: "abc123", media_type: "application/pdf")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["inlineData"]["data"]).to eq("abc123")
      expect(part["inlineData"]["mimeType"]).to eq("application/pdf")
    end

    it "infers MIME for InputFile base64 from filename extension" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_data: "abc123", filename: "report.pdf")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["inlineData"]["mimeType"]).to eq("application/pdf")
    end

    it "raises for InputFile base64 without media_type or filename extension" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_data: "abc123")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires InputFile\.media_type or a recognized filename extension/)
    end

    it "converts InputFile with file_id to fileData" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_id: "files/xyz", media_type: "application/pdf")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["fileData"]["fileUri"]).to eq("files/xyz")
      expect(part["fileData"]["mimeType"]).to eq("application/pdf")
    end

    it "converts InputVideo with URL to fileData" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputVideo.new(video_url: "https://example.com/video.mp4")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["fileData"]["fileUri"]).to eq("https://example.com/video.mp4")
      expect(part["fileData"]["mimeType"]).to eq("video/mp4")
    end

    it "raises for InputVideo without URL" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputVideo.new]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires InputVideo.video_url/)
    end

    it "drops RefusalContent silently so a parsed refusal can stay in session history" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hello")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::RefusalContent.new(refusal: "blocked")]
      ))
      session.user("Try again")

      h = described_class.request_payload(session)
      # The refusal-only model turn is skipped; the two user turns merge into one.
      expect(h["contents"].map { |c| c["role"] }).to eq(["user"])
    end

    it "raises for model-role InputImage" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::InputImage.new(image_url: "https://example.com/img.png")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /does not support assistant InputImage/)
    end

    it "passes thoughtSignature through on reasoning blocks" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Think")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        content: [{"type" => "thinking", "thinking" => "Let me think...", "signature" => "sig_123"}]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][1]["parts"][0]
      expect(part["thought"]).to eq(true)
      expect(part["text"]).to eq("Let me think...")
      expect(part["thoughtSignature"]).to eq("sig_123")
    end

    it "raises for redacted_thinking blocks" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Think")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        content: [{"type" => "redacted_thinking", "data" => "..."}]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /does not support redacted_thinking/)
    end

    it "raises for unrecognized reasoning block types instead of silently dropping them" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Think")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        content: [{"type" => "summary_text", "text" => "summary..."}]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /reasoning block type "summary_text"/)
    end

    it "raises when serializing a Reasoning item with only summary blocks" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        summary: [{"type" => "summary_text", "text" => "..."}]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /summary blocks/)
    end

    it "raises for unsupported session field: include" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", include: ["some"])
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /does not support session fields.*include/)
    end

    it "raises for unsupported session field: stream_options" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", stream_options: {})
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /does not support session fields.*stream_options/)
    end

    it "raises for unsupported session field: parallel_tool_calls" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", parallel_tool_calls: true)
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /does not support session fields.*parallel_tool_calls/)
    end

    it "raises for unsupported text sub-field" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        text: {"format" => {"type" => "json_object"}, "verbosity" => "high"}
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /does not support text.verbosity/)
    end

    it "raises for unsupported reasoning sub-field" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        reasoning: {"budget_tokens" => 5000, "effort" => "high"}
      )
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /does not support reasoning.effort/)
    end

    it "ignores session.stream because Gemini selects streaming via endpoint" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", stream: true)
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h).not_to have_key("stream")
    end

    it "omits stream flag if nil" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", stream: nil)
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h).not_to have_key("stream")
    end

    it "raises for tool_choice without tools" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", tool_choice: "auto")
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /tool_choice without tools/)
    end

    it "raises for unsupported tool_choice hash type" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        tool_choice: {"type" => "allowed_tools", "tools" => ["search"]}
      )
      session.register_tool("search") { |_| "ok" }
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /tool_choice/)
    end

    it "raises for function tool_choice without name" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        tool_choice: {"type" => "function"}
      )
      session.register_tool("test") { |_| "ok" }
      session.user("Hi")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /tool_choice\.name/)
    end

    it "omits toolConfig when tool_choice is nil" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.register_tool("test") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h).not_to have_key("toolConfig")
    end

    it "raises for model-role InputFile content" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::InputFile.new(file_url: "https://example.com/doc.pdf")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /assistant InputFile/)
    end

    it "raises for model-role InputVideo content" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::InputVideo.new(video_url: "https://example.com/video.mp4")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /assistant InputVideo/)
    end

    it "converts FunctionCallOutput with array content to string" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Weather?")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "get_weather", call_id: "call_1", arguments: '{"city":"London"}'
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "call_1",
        output: [PromptBuilder::Content::InputText.new(text: "72F sunny")]
      ))

      h = described_class.request_payload(session)
      result = h["contents"][2]["parts"][0]["functionResponse"]["response"]["result"]
      expect(result).to eq("72F sunny")
    end

    it "raises when FunctionCallOutput contains non-text content" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Look at this")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "fetch", call_id: "call_1", arguments: "{}"
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "call_1",
        output: [PromptBuilder::Content::InputImage.new(
          image_url: "gs://bucket/img.png", media_type: "image/png"
        )]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /tool output in Gemini/)
    end

    it "falls back to call_id when function name cannot be resolved" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Weather?")
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "unknown_call", output: "result"
      ))

      h = described_class.request_payload(session)
      # FunctionCallOutput has "user" role and merges with preceding user message
      func_response_part = h["contents"][0]["parts"].find { |p| p["functionResponse"] }
      expect(func_response_part["functionResponse"]["name"]).to eq("unknown_call")
    end

    it "wraps multiple tools in a single tools array element" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.register_tool("get_weather", description: "Get weather") { |_| "sunny" }
      session.register_tool("get_time", description: "Get time") { |_| "noon" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tools"].length).to eq(1)
      expect(h["tools"][0]["functionDeclarations"].length).to eq(2)
    end

    it "defaults tool parameters when not specified" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.register_tool("test") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["tools"][0]["functionDeclarations"][0]["parameters"]).to eq({"type" => "object", "properties" => {}})
    end

    it "omits generationConfig when no config fields are set" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h).not_to have_key("generationConfig")
    end

    it "raises for unsupported session fields: background, max_tool_calls, safety_identifier" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", background: true)
      session.user("Hi")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /background/)

      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", max_tool_calls: 5)
      session.user("Hi")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /max_tool_calls/)

      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", safety_identifier: "safe_1")
      session.user("Hi")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /safety_identifier/)
    end

    it "raises for unsupported session fields: prompt_cache_key, truncation, store" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", prompt_cache_key: "cache_1")
      session.user("Hi")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /prompt_cache_key/)

      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", truncation: "auto")
      session.user("Hi")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /truncation/)

      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", store: true)
      session.user("Hi")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /store/)
    end

    it "raises for unsupported session fields: top_logprobs, service_tier, metadata" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", top_logprobs: 5)
      session.user("Hi")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /top_logprobs/)

      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", service_tier: "auto")
      session.user("Hi")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /service_tier/)

      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", metadata: {"key" => "value"})
      session.user("Hi")
      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /metadata/)
    end

    it "can be resolved via symbol alias" do
      serializer = PromptBuilder::Serializers.resolve(:gemini)
      expect(serializer).to eq(described_class)
    end

    it "raises for InputFile without URL, data, or file_id" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires InputFile\.file_url, InputFile\.file_data, or InputFile\.file_id/)
    end

    it "raises for Compaction items" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Compaction.new(encrypted_content: "abc"))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /Compaction/)
    end

    it "raises for ItemReference items" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::ItemReference.new(id: "msg_1"))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /ItemReference/)
    end
  end

  describe ".parse_response" do
    it "parses basic text response" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {
              "parts" => [{"text" => "Hello back!"}]
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => {
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 5,
          "totalTokenCount" => 15
        }
      }

      response = described_class.parse_response(response_hash)
      expect(response.model).to eq("gemini-2.0-flash")
      expect(response.status).to eq("completed")
      expect(response.output.length).to eq(1)

      message = response.output[0]
      expect(message).to be_a(PromptBuilder::Items::Message)
      expect(message.role).to eq("assistant")
      expect(message.content[0].text).to eq("Hello back!")

      expect(response.usage.input_tokens).to eq(10)
      expect(response.usage.output_tokens).to eq(5)
      expect(response.usage.total_tokens).to eq(15)
    end

    it "parses function call response" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {
              "parts" => [
                {
                  "functionCall" => {
                    "name" => "get_weather",
                    "args" => {"city" => "London"}
                  }
                }
              ]
            },
            "finishReason" => "STOP"
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      expect(response.output.length).to eq(1)

      func_call = response.output[0]
      expect(func_call).to be_a(PromptBuilder::Items::FunctionCall)
      expect(func_call.name).to eq("get_weather")
      expect(func_call.call_id).to eq("gemini_call_0")
      expect(func_call.parsed_arguments).to eq({"city" => "London"})
    end

    it "preserves thoughtSignature on thinking response" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {
              "parts" => [
                {"thought" => true, "text" => "Let me think...", "thoughtSignature" => "sig_xyz"}
              ]
            },
            "finishReason" => "STOP"
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      reasoning = response.output[0]
      expect(reasoning).to be_a(PromptBuilder::Items::Reasoning)
      expect(reasoning.content[0]["signature"]).to eq("sig_xyz")
    end

    it "parses thinking response" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {
              "parts" => [
                {"thought" => true, "text" => "Let me think..."},
                {"text" => "The answer is 42"}
              ]
            },
            "finishReason" => "STOP"
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      expect(response.output.length).to eq(2)

      reasoning = response.output[0]
      expect(reasoning).to be_a(PromptBuilder::Items::Reasoning)
      expect(reasoning.content[0]["thinking"]).to eq("Let me think...")

      message = response.output[1]
      expect(message).to be_a(PromptBuilder::Items::Message)
      expect(message.content[0].text).to eq("The answer is 42")
    end

    it "maps STOP finish reason to completed" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {"parts" => [{"text" => "Hi"}]},
            "finishReason" => "STOP"
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      expect(response.status).to eq("completed")
    end

    it "maps MAX_TOKENS finish reason to incomplete" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {"parts" => [{"text" => "Hi"}]},
            "finishReason" => "MAX_TOKENS"
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      expect(response.status).to eq("incomplete")
    end

    it "maps SAFETY finish reason to failed" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {"parts" => [{"text" => "Hi"}]},
            "finishReason" => "SAFETY"
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      expect(response.status).to eq("failed")
    end

    it "includes cached_tokens in usage input_tokens_details" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {"parts" => [{"text" => "Hi"}]},
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => {
          "promptTokenCount" => 100,
          "candidatesTokenCount" => 10,
          "totalTokenCount" => 110,
          "cachedContentTokenCount" => 50
        }
      }

      response = described_class.parse_response(response_hash)
      expect(response.usage.input_tokens_details["cached_tokens"]).to eq(50)
    end

    it "includes reasoning_tokens in usage output_tokens_details" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {"parts" => [{"text" => "Hi"}]},
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => {
          "promptTokenCount" => 100,
          "candidatesTokenCount" => 10,
          "totalTokenCount" => 110,
          "thoughtsTokenCount" => 5
        }
      }

      response = described_class.parse_response(response_hash)
      expect(response.usage.output_tokens_details["reasoning_tokens"]).to eq(5)
    end

    it "handles missing candidates" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => []
      }

      response = described_class.parse_response(response_hash)
      expect(response.output).to eq([])
    end

    it "handles missing usageMetadata" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {"parts" => [{"text" => "Hi"}]},
            "finishReason" => "STOP"
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      expect(response.usage).to be_nil
    end

    it "has nil id and object fields" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {"parts" => [{"text" => "Hi"}]},
            "finishReason" => "STOP"
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      expect(response.id).to be_nil
      expect(response.object).to be_nil
    end

    it "maps RECITATION finish reason to failed" do
      response_hash = {
        "candidates" => [
          {
            "content" => {"parts" => []},
            "finishReason" => "RECITATION"
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      expect(response.status).to eq("failed")
    end

    it "assigns sequential synthetic call_ids to multiple tool calls" do
      response_hash = {
        "candidates" => [
          {
            "content" => {
              "parts" => [
                {"functionCall" => {"name" => "get_weather", "args" => {"city" => "London"}}},
                {"functionCall" => {"name" => "get_time", "args" => {"tz" => "UTC"}}}
              ]
            },
            "finishReason" => "STOP"
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      expect(response.tool_calls.length).to eq(2)
      expect(response.tool_calls[0].call_id).to eq("gemini_call_0")
      expect(response.tool_calls[0].name).to eq("get_weather")
      expect(response.tool_calls[1].call_id).to eq("gemini_call_1")
      expect(response.tool_calls[1].name).to eq("get_time")
    end

    it "handles empty functionCall args" do
      response_hash = {
        "candidates" => [
          {
            "content" => {
              "parts" => [{"functionCall" => {"name" => "no_args"}}]
            },
            "finishReason" => "STOP"
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      expect(response.tool_calls[0].parsed_arguments).to eq({})
    end

    it "can be added to a session" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hello")

      response = described_class.parse_response({
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {"parts" => [{"text" => "Hi there!"}]},
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => {
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 5,
          "totalTokenCount" => 15
        }
      })
      session.add_response(response)

      expect(session.items.length).to eq(2)
      expect(session.items[1]).to be_a(PromptBuilder::Items::Message)
      expect(session.items[1].role).to eq("assistant")
    end
  end
end
