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
      expect(h.include?("model")).to be(false)
      expect(h["generationConfig"]["temperature"]).to eq(0.7)
      expect(h["generationConfig"]["maxOutputTokens"]).to eq(1024)
      expect(h["systemInstruction"]["parts"]).to eq([{"text" => "You are helpful."}])
      expect(h["contents"].length).to eq(1)
      expect(h["contents"][0]["role"]).to eq("user")
      expect(h["contents"][0]["parts"]).to eq([{"text" => "Hello"}])
    end

    it "raises when model is missing" do
      session = PromptBuilder::Session.new
      session.user("Hello")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires session.model/)
    end

    it "raises when there are no user/model messages" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", instructions: "Be helpful")

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /at least one user\/model message/)
    end

    it "merges system and developer messages into systemInstruction" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", instructions: "Base instruction")
      session.system("Extra system context")
      session.developer("Developer note")
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["systemInstruction"]["parts"].length).to eq(3)
      expect(h["systemInstruction"]["parts"][0]["text"]).to eq("Extra system context")
      expect(h["systemInstruction"]["parts"][1]["text"]).to eq("Developer note")
      expect(h["systemInstruction"]["parts"][2]["text"]).to eq("Base instruction")
      # System/developer messages should not appear in contents array
      expect(h["contents"].length).to eq(1)
    end

    it "serializes OutputText content in system messages into systemInstruction" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "system",
        content: [PromptBuilder::Content::OutputText.new(text: "From history")]
      ))
      session.user("Hello")

      h = described_class.request_payload(session)
      expect(h["systemInstruction"]["parts"]).to eq([{"text" => "From history"}])
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
      expect(model_content["parts"][0]["functionCall"]["id"]).to eq("call_1")
    end

    it "preserves thoughtSignature on FunctionCall and OutputText parts" do
      session = PromptBuilder::Session.new(model: "gemini-3-flash-preview")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "get_weather",
        call_id: "call_1",
        arguments: {"city" => "London"},
        thought_signature: "sig_call"
      ))
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::OutputText.new(text: "Checking", thought_signature: "sig_text")]
      ))

      h = described_class.request_payload(session)
      expect(h["contents"][0]["parts"][0]["thoughtSignature"]).to eq("sig_call")
      expect(h["contents"][0]["parts"][1]["thoughtSignature"]).to eq("sig_text")
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
      expect(response_content["parts"][0]["functionResponse"]["id"]).to eq("call_1")
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

    it "maps presence_penalty to generationConfig.presencePenalty" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", presence_penalty: 0.1)
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["presencePenalty"]).to eq(0.1)
    end

    it "maps frequency_penalty to generationConfig.frequencyPenalty" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", frequency_penalty: 0.2)
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["frequencyPenalty"]).to eq(0.2)
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

    it "maps reasoning effort and auto summary to thinkingConfig" do
      session = PromptBuilder::Session.new(
        model: "gemini-3-flash-preview",
        reasoning: {"effort" => "medium", "summary" => "auto"}
      )
      session.user("Think clearly")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["thinkingConfig"]).to eq({
        "thinkingLevel" => "MEDIUM",
        "includeThoughts" => true
      })
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
        content: [PromptBuilder::Content::InputImage.new(url: "gs://bucket/img.png", media_type: "image/png")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["fileData"]["fileUri"]).to eq("gs://bucket/img.png")
      expect(part["fileData"]["mimeType"]).to eq("image/png")
    end

    it "passes through InputImage with arbitrary public URL" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(url: "https://example.com/img.png")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["fileData"]["fileUri"]).to eq("https://example.com/img.png")
      expect(part["fileData"]["mimeType"]).to eq("image/jpeg")
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
        content: [PromptBuilder::Content::InputImage.new(url: "data:image/png;base64,abc123")]
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
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires InputImage\.url or a file_id in extra/)
    end

    it "converts InputImage with data URL to inlineData" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(url: "data:image/png;base64,abc123")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["inlineData"]["data"]).to eq("abc123")
      expect(part["inlineData"]["mimeType"]).to eq("image/png")
    end

    it "converts InputFile with a gs:// URL to fileData and infers mime from filename" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(url: "gs://bucket/file.pdf")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["fileData"]["fileUri"]).to eq("gs://bucket/file.pdf")
      expect(part["fileData"]["mimeType"]).to eq("application/pdf")
    end

    it "passes through InputFile with arbitrary public URL" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(url: "https://example.com/file.pdf")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["fileData"]["fileUri"]).to eq("https://example.com/file.pdf")
      expect(part["fileData"]["mimeType"]).to eq("application/pdf")
    end

    it "converts InputFile with base64 data to inlineData using explicit media_type" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(url: "data:application/pdf;base64,abc123", media_type: "application/pdf")]
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
        content: [PromptBuilder::Content::InputFile.new(url: "data:application/octet-stream;base64,abc123", filename: "report.pdf")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["inlineData"]["mimeType"]).to eq("application/pdf")
    end

    it "infers MIME for audio InputFile base64 from filename extension" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(url: "data:application/octet-stream;base64,abc123", filename: "clip.mp3")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["inlineData"]["mimeType"]).to eq("audio/mpeg")
    end

    it "raises for InputFile base64 without media_type or filename extension" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(url: "data:application/octet-stream;base64,abc123")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires media_type in extra or a recognized filename extension/)
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

    it "raises for InputFile with file_id but no media_type" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(file_id: "files/xyz")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires media_type in extra when using file_id/)
    end

    it "raises for InputFile with gs:// URL but no media_type or recognizable extension" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(url: "gs://bucket/file")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires media_type in extra or a recognized filename extension/)
    end

    it "converts InputVideo with a Google-hosted URL to fileData" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputVideo.new(url: "gs://my-bucket/video.mp4")]
      ))

      h = described_class.request_payload(session)
      part = h["contents"][0]["parts"][0]
      expect(part["fileData"]["fileUri"]).to eq("gs://my-bucket/video.mp4")
      expect(part["fileData"]["mimeType"]).to eq("video/mp4")
    end

    it "passes through InputVideo with arbitrary public URL" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputVideo.new(url: "https://example.com/video.mp4")]
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
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires InputVideo.url/)
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

    it "omits model-role InputImage" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::InputImage.new(url: "https://example.com/img.png")]
      ))

      h = described_class.request_payload(session)
      expect(h["contents"]).to eq([{"role" => "user", "parts" => [{"text" => "Hi"}]}])
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

    it "silently skips redacted_thinking blocks" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Think")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        content: [
          {"type" => "thinking", "thinking" => "Let me think...", "signature" => "sig1"},
          {"type" => "redacted_thinking", "data" => "..."}
        ]
      ))

      h = described_class.request_payload(session)
      model_parts = h["contents"].find { |c| c["role"] == "model" }["parts"]
      expect(model_parts.length).to eq(1)
      expect(model_parts[0]["thought"]).to eq(true)
      expect(model_parts[0]["text"]).to eq("Let me think...")
    end

    it "silently skips unrecognized reasoning block types" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Think")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        content: [{"type" => "summary_text", "text" => "summary..."}]
      ))

      h = described_class.request_payload(session)
      roles = h["contents"].map { |c| c["role"] }
      expect(roles).to eq(["user"])
    end

    it "silently skips Reasoning items with only summary blocks" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        summary: [{"type" => "summary_text", "text" => "..."}]
      ))

      h = described_class.request_payload(session)
      roles = h["contents"].map { |c| c["role"] }
      expect(roles).to eq(["user"])
    end

    it "omits unsupported session field: include" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", include: ["some"])
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h).not_to have_key("include")
    end

    it "omits unsupported session field: stream_options" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", stream_options: {})
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h).not_to have_key("stream_options")
    end

    it "omits unsupported session field: parallel_tool_calls" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", parallel_tool_calls: true)
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h).not_to have_key("parallel_tool_calls")
    end

    it "omits unsupported text sub-fields while mapping the supported ones" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        text: {"format" => {"type" => "json_object"}, "verbosity" => "high"}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["responseMimeType"]).to eq("application/json")
      expect(h["generationConfig"]).not_to have_key("verbosity")
    end

    it "omits unsupported reasoning sub-fields while mapping the supported ones" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        reasoning: {"budget_tokens" => 5000, "display" => "visible"}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["thinkingConfig"]).to eq({"thinkingBudget" => 5000})
    end

    it "omits unsupported reasoning effort and summary values" do
      session = PromptBuilder::Session.new(model: "gemini-3-flash-preview", reasoning: {"effort" => "extreme"})
      session.user("Hi")
      h = described_class.request_payload(session)
      expect(h.dig("generationConfig", "thinkingConfig")).to be_nil

      session = PromptBuilder::Session.new(model: "gemini-3-flash-preview", reasoning: {"summary" => "detailed"})
      session.user("Hi")
      h = described_class.request_payload(session)
      expect(h.dig("generationConfig", "thinkingConfig")).to be_nil
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

    it "omits tool_choice without tools" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", tool_choice: "auto")
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h).not_to have_key("toolConfig")
    end

    it "omits an unsupported tool_choice hash type" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        tool_choice: {"type" => "allowed_tools", "tools" => ["search"]}
      )
      session.register_tool("search") { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h).not_to have_key("toolConfig")
      expect(h["tools"]).not_to be_nil
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

    it "omits model-role InputFile content" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::InputFile.new(url: "https://example.com/doc.pdf")]
      ))

      h = described_class.request_payload(session)
      expect(h["contents"]).to eq([{"role" => "user", "parts" => [{"text" => "Hi"}]}])
    end

    it "omits model-role InputVideo content" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::InputVideo.new(url: "https://example.com/video.mp4")]
      ))

      h = described_class.request_payload(session)
      expect(h["contents"]).to eq([{"role" => "user", "parts" => [{"text" => "Hi"}]}])
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

    it "omits non-text content in FunctionCallOutput" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Look at this")
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "fetch", call_id: "call_1", arguments: "{}"
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "call_1",
        output: [PromptBuilder::Content::InputImage.new(
          url: "gs://bucket/img.png", extra: {"media_type" => "image/png"}
        )]
      ))

      h = described_class.request_payload(session)
      result = h["contents"][2]["parts"][0]["functionResponse"]["response"]["result"]
      expect(result).to eq("")
    end

    it "raises when FunctionCallOutput cannot be matched to a FunctionCall" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Weather?")
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "unknown_call", output: "result"
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /matching FunctionCall/)
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

    it "omits unsupported session fields: background, max_tool_calls, safety_identifier" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", background: true)
      session.user("Hi")
      expect(described_class.request_payload(session)).not_to have_key("background")

      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", max_tool_calls: 5)
      session.user("Hi")
      expect(described_class.request_payload(session)).not_to have_key("max_tool_calls")

      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", safety_identifier: "safe_1")
      session.user("Hi")
      expect(described_class.request_payload(session)).not_to have_key("safety_identifier")
    end

    it "omits unsupported session fields: prompt_cache_key, truncation" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", prompt_cache_key: "cache_1")
      session.user("Hi")
      expect(described_class.request_payload(session)).not_to have_key("prompt_cache_key")

      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", truncation: "auto")
      session.user("Hi")
      expect(described_class.request_payload(session)).not_to have_key("truncation")
    end

    it "maps store and supported service_tier values" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", store: false, service_tier: "flex")
      session.user("Hi")
      h = described_class.request_payload(session)
      expect(h["store"]).to eq(false)
      expect(h["serviceTier"]).to eq("flex")
    end

    it "omits unsupported service_tier values and metadata" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", service_tier: "auto")
      session.user("Hi")
      expect(described_class.request_payload(session)).not_to have_key("serviceTier")

      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", metadata: {"key" => "value"})
      session.user("Hi")
      h = described_class.request_payload(session)
      expect(h).not_to have_key("metadata")
    end

    it "maps top_logprobs to responseLogprobs and logprobs" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash", top_logprobs: 5)
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["responseLogprobs"]).to eq(true)
      expect(h["generationConfig"]["logprobs"]).to eq(5)
    end

    it "maps text format text to responseMimeType text/plain" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        text: {"format" => {"type" => "text"}}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["responseMimeType"]).to eq("text/plain")
    end

    it "omits the strict flag on tool definitions" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.register_tool("test", strict: true) { |_| "ok" }
      session.user("Hi")

      h = described_class.request_payload(session)
      function_declaration = h["tools"][0]["functionDeclarations"][0]
      expect(function_declaration["name"]).to eq("test")
      expect(function_declaration).not_to have_key("strict")
    end

    it "omits an unknown text.format type" do
      session = PromptBuilder::Session.new(
        model: "gemini-2.0-flash",
        text: {"format" => {"type" => "json_array"}}
      )
      session.user("Hi")

      h = described_class.request_payload(session)
      expect(h.dig("generationConfig", "responseMimeType")).to be_nil
      expect(h.dig("generationConfig", "responseSchema")).to be_nil
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
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /requires InputFile\.url or file_id in extra/)
    end

    it "silently skips Compaction items" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::Compaction.new(encrypted_content: "abc"))

      h = described_class.request_payload(session)
      expect(h["contents"]).to eq([{"role" => "user", "parts" => [{"text" => "Hi"}]}])
    end

    it "silently skips ItemReference items" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")
      session.add_item(PromptBuilder::Items::ItemReference.new(id: "msg_1"))

      h = described_class.request_payload(session)
      expect(h["contents"]).to eq([{"role" => "user", "parts" => [{"text" => "Hi"}]}])
    end
  end

  describe ".parse_response" do
    it "raises an ErrorResponseError for a Gemini error envelope" do
      expect {
        described_class.parse_response({
          "error" => {
            "code" => 400,
            "message" => "API key not valid. Please pass a valid API key.",
            "status" => "INVALID_ARGUMENT"
          }
        })
      }.to raise_error(PromptBuilder::ErrorResponseError, "the API returned an error: INVALID_ARGUMENT: API key not valid. Please pass a valid API key.")
    end

    it "raises an UnexpectedPayloadError for unrecognized payloads" do
      expect {
        described_class.parse_response({"foo" => "bar"})
      }.to raise_error(PromptBuilder::UnexpectedPayloadError, /missing "candidates"/)
    end

    it "preserves responseId" do
      response_hash = {
        "responseId" => "resp_xyz",
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {"content" => {"parts" => [{"text" => "ok"}]}, "finishReason" => "STOP"}
        ]
      }
      response = described_class.parse_response(response_hash)
      expect(response.id).to eq("resp_xyz")
    end

    it "marks safety-blocked prompts as failed even when candidates is empty" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [],
        "promptFeedback" => {"blockReason" => "SAFETY"}
      }
      response = described_class.parse_response(response_hash)
      expect(response.status).to eq("failed")
    end

    it "maps newer FinishReason values to failed" do
      %w[BLOCKLIST PROHIBITED_CONTENT SPII MALFORMED_FUNCTION_CALL IMAGE_SAFETY LANGUAGE
        UNEXPECTED_TOOL_CALL TOO_MANY_TOOL_CALLS MODEL_ARMOR IMAGE_PROHIBITED_CONTENT IMAGE_OTHER NO_IMAGE
        IMAGE_RECITATION MISSING_THOUGHT_SIGNATURE MALFORMED_RESPONSE].each do |reason|
        response = described_class.parse_response({
          "modelVersion" => "gemini-2.0-flash",
          "candidates" => [{"content" => {"parts" => [{"text" => ""}]}, "finishReason" => reason}]
        })
        expect(response.status).to eq("failed"), "expected #{reason} to map to failed"
      end
    end

    it "treats FINISH_REASON_UNSPECIFIED as nil status" do
      response = described_class.parse_response({
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [{"content" => {"parts" => [{"text" => "x"}]}, "finishReason" => "FINISH_REASON_UNSPECIFIED"}]
      })
      expect(response.status).to be_nil
    end

    it "parses only the first candidate when multiple are present" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {"content" => {"parts" => [{"text" => "one"}]}, "finishReason" => "STOP"},
          {"content" => {"parts" => [{"text" => "two"}]}, "finishReason" => "STOP"}
        ]
      }

      response = described_class.parse_response(response_hash)
      expect(response.output.length).to eq(1)
      expect(response.output[0].content[0].text).to eq("one")
    end

    it "skips unknown response Part shapes (executableCode, codeExecutionResult, inlineData, fileData)" do
      %w[executableCode codeExecutionResult inlineData fileData toolCall toolResponse].each do |key|
        response_hash = {
          "modelVersion" => "gemini-2.0-flash",
          "candidates" => [
            {
              "content" => {"parts" => [{key => {"foo" => "bar"}}, {"text" => "hi"}]},
              "finishReason" => "STOP"
            }
          ]
        }
        response = described_class.parse_response(response_hash)
        expect(response.output.length).to eq(1), "expected #{key} part to be skipped"
        expect(response.output[0].content[0].text).to eq("hi")
      end
    end

    it "skips a response Part with no recognized content key" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {
            "content" => {"parts" => [{"unknownKey" => "x"}]},
            "finishReason" => "STOP"
          }
        ]
      }
      response = described_class.parse_response(response_hash)
      expect(response.output).to eq([])
    end

    it "preserves text parts whose text is an empty string" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [
          {"content" => {"parts" => [{"text" => ""}]}, "finishReason" => "STOP"}
        ]
      }
      response = described_class.parse_response(response_hash)
      expect(response.output.length).to eq(1)
      expect(response.output[0].content[0].text).to eq("")
    end

    it "surfaces grounding, citation, safety, and logprobs metadata on extra" do
      response_hash = {
        "responseId" => "resp_xyz",
        "modelVersion" => "gemini-2.0-flash",
        "createTime" => "2026-05-04T12:00:00Z",
        "modelStatus" => {"modelStage" => "STABLE"},
        "promptFeedback" => {"safetyRatings" => [{"category" => "HARM_CATEGORY_HARASSMENT", "probability" => "NEGLIGIBLE"}]},
        "candidates" => [
          {
            "index" => 0,
            "content" => {"parts" => [{"text" => "ok"}]},
            "finishReason" => "STOP",
            "finishMessage" => "natural stop",
            "safetyRatings" => [{"category" => "HARM_CATEGORY_HATE_SPEECH", "probability" => "LOW"}],
            "citationMetadata" => {"citationSources" => [{"uri" => "https://example.com"}]},
            "groundingMetadata" => {"webSearchQueries" => ["weather paris"]},
            "urlContextMetadata" => {"urls" => ["https://example.com"]},
            "avgLogprobs" => -0.5,
            "logprobsResult" => {"chosenCandidates" => []}
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      data = response.extra
      expect(data["create_time"]).to eq("2026-05-04T12:00:00Z")
      expect(data["model_status"]).to eq({"modelStage" => "STABLE"})
      expect(data["prompt_feedback"]).to be_a(Hash)
      expect(data["index"]).to eq(0)
      expect(data["safety_ratings"][0]["category"]).to eq("HARM_CATEGORY_HATE_SPEECH")
      expect(data["citation_metadata"]["citationSources"][0]["uri"]).to eq("https://example.com")
      expect(data["grounding_metadata"]["webSearchQueries"]).to eq(["weather paris"])
      expect(data["url_context_metadata"]["urls"]).to eq(["https://example.com"])
      expect(data["avg_logprobs"]).to eq(-0.5)
      expect(data["logprobs_result"]).to eq({"chosenCandidates" => []})
      expect(data["finish_message"]).to eq("natural stop")
    end

    it "leaves extra nil when no metadata is present" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [{"content" => {"parts" => [{"text" => "x"}]}, "finishReason" => "STOP"}]
      }
      response = described_class.parse_response(response_hash)
      expect(response.extra).to be_nil
    end

    it "surfaces additional usage breakdowns (tool-use prompt tokens and modality details)" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
        "candidates" => [{"content" => {"parts" => [{"text" => "ok"}]}, "finishReason" => "STOP"}],
        "usageMetadata" => {
          "promptTokenCount" => 100,
          "candidatesTokenCount" => 10,
          "totalTokenCount" => 110,
          "toolUsePromptTokenCount" => 7,
          "promptTokensDetails" => [{"modality" => "TEXT", "tokenCount" => 100}],
          "cacheTokensDetails" => [{"modality" => "TEXT", "tokenCount" => 50}],
          "candidatesTokensDetails" => [{"modality" => "TEXT", "tokenCount" => 10}],
          "toolUsePromptTokensDetails" => [{"modality" => "TEXT", "tokenCount" => 7}]
        }
      }

      response = described_class.parse_response(response_hash)
      input_details = response.usage.input_tokens_details
      output_details = response.usage.output_tokens_details
      expect(input_details["tool_use_prompt_tokens"]).to eq(7)
      expect(input_details["prompt_tokens_details"]).to eq([{"modality" => "TEXT", "tokenCount" => 100}])
      expect(input_details["cache_tokens_details"]).to eq([{"modality" => "TEXT", "tokenCount" => 50}])
      expect(input_details["tool_use_prompt_tokens_details"]).to eq([{"modality" => "TEXT", "tokenCount" => 7}])
      expect(output_details["candidates_tokens_details"]).to eq([{"modality" => "TEXT", "tokenCount" => 10}])
    end

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
                  "thoughtSignature" => "sig_call",
                  "functionCall" => {
                    "id" => "call_abc",
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
      expect(func_call.call_id).to eq("call_abc")
      expect(func_call.extra).to eq({"thought_signature" => "sig_call"})
      expect(func_call.parsed_arguments).to eq({"city" => "London"})
    end

    it "preserves thoughtSignature on text response parts" do
      response_hash = {
        "modelVersion" => "gemini-3-flash-preview",
        "candidates" => [
          {
            "content" => {
              "parts" => [
                {"text" => "Answer", "thoughtSignature" => "sig_text"}
              ]
            },
            "finishReason" => "STOP"
          }
        ]
      }

      response = described_class.parse_response(response_hash)
      text = response.output[0].content[0]
      expect(text).to be_a(PromptBuilder::Content::OutputText)
      expect(text.extra).to eq({"thought_signature" => "sig_text"})
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
        "modelVersion" => "gemini-2.0-flash",
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
        "modelVersion" => "gemini-2.0-flash",
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
      expect(response.tool_calls[0].call_id).to match(/\Agemini_call_[0-9a-f]+_0\z/)
      expect(response.tool_calls[0].name).to eq("get_weather")
      expect(response.tool_calls[1].call_id).to match(/\Agemini_call_[0-9a-f]+_1\z/)
      expect(response.tool_calls[1].name).to eq("get_time")
      # Both calls must share the same response-scoped seed
      seed1 = response.tool_calls[0].call_id[%r{^gemini_call_([0-9a-f]+)_}, 1]
      seed2 = response.tool_calls[1].call_id[%r{^gemini_call_([0-9a-f]+)_}, 1]
      expect(seed1).to eq(seed2)
    end

    it "handles empty functionCall args" do
      response_hash = {
        "modelVersion" => "gemini-2.0-flash",
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

  describe "session helpers" do
    it "serializes Session#json_output to responseSchema" do
      schema = {"type" => "object", "properties" => {"answer" => {"type" => "string"}}}
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")
      session.json_output(schema)

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["responseMimeType"]).to eq("application/json")
      expect(h["generationConfig"]["responseSchema"]).to eq(schema)
    end

    it "serializes Session#think effort to thinkingConfig.thinkingLevel" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")
      session.think(effort: :medium)

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["thinkingConfig"]).to eq({"thinkingLevel" => "MEDIUM"})
    end

    it "serializes Session#think budget_tokens to thinkingConfig.thinkingBudget" do
      session = PromptBuilder::Session.new(model: "gemini-2.0-flash")
      session.user("Hi")
      session.think(budget_tokens: 8_000)

      h = described_class.request_payload(session)
      expect(h["generationConfig"]["thinkingConfig"]).to eq({"thinkingBudget" => 8_000})
    end
  end
end
