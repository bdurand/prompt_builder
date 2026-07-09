# frozen_string_literal: true

require "spec_helper"
require "json"
require "json-schema"

RSpec.describe PromptBuilder::Serializers::OpenResponses do
  describe ".request_payload" do
    it "returns session.to_h for local state sessions" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.user("Hello")

      expect(described_class.request_payload(session)).to eq(session.to_h)
    end

    it "returns session.to_h for server state sessions" do
      session = PromptBuilder::Session.new(previous_response_id: "resp_123")
      session.user("follow up")

      expect(described_class.request_payload(session)).to eq(session.to_h)
    end

    it "passes through InputImage with url unchanged" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(url: "https://example.com/img.png")]
      ))

      payload = described_class.request_payload(session)
      content = payload["input"][0]["content"][0]

      expect(content["type"]).to eq("input_image")
      expect(content["image_url"]).to eq("https://example.com/img.png")
      expect(content).not_to have_key("data")
      expect(content).not_to have_key("media_type")
    end

    it "passes through InputImage with data URL unchanged" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(url: "data:image/png;base64,abc123")]
      ))

      payload = described_class.request_payload(session)
      content = payload["input"][0]["content"][0]

      expect(content["type"]).to eq("input_image")
      expect(content["image_url"]).to eq("data:image/png;base64,abc123")
    end

    it "normalizes blank url when file_id is present" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(url: "  ", file_id: "file_abc")]
      ))

      payload = described_class.request_payload(session)
      content = payload["input"][0]["content"][0]

      expect(content["type"]).to eq("input_image")
      expect(content["file_id"]).to eq("file_abc")
      expect(content).not_to have_key("image_url")
    end

    it "raises when InputImage includes both url and file_id" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(url: "https://example.com/img.png", file_id: "file_abc")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::InvalidItemError, /exactly one/)
    end

    it "raises when InputImage includes neither url nor file_id" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(detail: "high")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::InvalidItemError, /requires exactly one of image_url or file_id/)
    end

    it "strips extra keys from items and content" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(
          url: "https://example.com/img.png",
          extra: {"some_key" => "value"}
        )]
      ))

      payload = described_class.request_payload(session)
      content = payload["input"][0]["content"][0]

      expect(content["image_url"]).to eq("https://example.com/img.png")
      expect(content).not_to have_key("extra")
      expect(content).not_to have_key("some_key")
    end

    it "strips provider-specific extras that are serialized flat into content, item, and tool hashes" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.system([PromptBuilder::Content::InputText.new(text: "sys", cache_control: {"type" => "ephemeral"})])
      session.user([
        PromptBuilder::Content::InputText.new(text: "ctx", cache_point: true),
        PromptBuilder::Content::InputFile.new(file_id: "file_123", media_type: "application/pdf", citations: {"enabled" => true})
      ])
      session.add_item(PromptBuilder::Items::FunctionCall.new(
        name: "f", call_id: "call_1", arguments: "{}", thought_signature: "sig123"
      ))
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(call_id: "call_1", output: "ok"))
      session.register_tool(
        "search",
        parameters: {"type" => "object", "properties" => {}},
        cache_control: {"type" => "ephemeral"}
      )

      payload = described_class.request_payload(session)
      json = JSON.generate(payload)

      expect(json).not_to include("cache_control")
      expect(json).not_to include("cache_point")
      expect(json).not_to include("citations")
      expect(json).not_to include("media_type")
      expect(json).not_to include("thought_signature")

      file_block = payload["input"][1]["content"][1]
      expect(file_block).to eq({"type" => "input_file", "file_id" => "file_123"})
    end

    it "strips extras from items appended after the response boundary in server state mode" do
      session = PromptBuilder::Session.new(model: "gpt-5.4", previous_response_id: "resp_0")
      session.user([PromptBuilder::Content::InputText.new(text: "hi", cache_control: {"type" => "ephemeral"})])

      payload = described_class.request_payload(session)

      expect(payload["previous_response_id"]).to eq("resp_0")
      expect(payload["input"][0]["content"][0]).to eq({"type" => "input_text", "text" => "hi"})
    end

    it "serializes InputFile with data URL as file_data" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(url: "data:application/pdf;base64,abc123", filename: "doc.pdf")]
      ))

      payload = described_class.request_payload(session)
      content = payload["input"][0]["content"][0]

      expect(content["type"]).to eq("input_file")
      expect(content["file_data"]).to eq("data:application/pdf;base64,abc123")
      expect(content["filename"]).to eq("doc.pdf")
      expect(content).not_to have_key("url")
    end

    it "serializes InputFile with http URL as file_url" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputFile.new(url: "https://example.com/doc.pdf", filename: "doc.pdf")]
      ))

      payload = described_class.request_payload(session)
      content = payload["input"][0]["content"][0]

      expect(content["type"]).to eq("input_file")
      expect(content["file_url"]).to eq("https://example.com/doc.pdf")
      expect(content["filename"]).to eq("doc.pdf")
      expect(content).not_to have_key("url")
    end

    it "strips extra from FunctionCallOutput content" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "c1",
        output: [PromptBuilder::Content::InputImage.new(
          url: "data:image/png;base64,abc",
          extra: {"some_key" => "val"}
        )]
      ))

      payload = described_class.request_payload(session)
      content = payload["input"][0]["output"][0]

      expect(content["image_url"]).to eq("data:image/png;base64,abc")
      expect(content).not_to have_key("extra")
      expect(content).not_to have_key("some_key")
    end

    it "strips reasoning items without encrypted_content" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.user("Hello")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        id: "rs_1",
        status: "completed",
        content: [{"type" => "reasoning_text", "text" => "Thinking..."}]
      ))
      session.assistant([PromptBuilder::Content::OutputText.new(text: "Hi!")])

      payload = described_class.request_payload(session)
      types = payload["input"].map { |i| i["type"] }

      expect(types).to eq(["message", "message"])
      expect(types).not_to include("reasoning")
    end

    it "preserves reasoning items with encrypted_content" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.user("Hello")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        id: "rs_1",
        encrypted_content: "encrypted_blob",
        summary: [{"type" => "summary_text", "text" => "Considered the request."}]
      ))
      session.assistant([PromptBuilder::Content::OutputText.new(text: "Hi!")])

      payload = described_class.request_payload(session)
      types = payload["input"].map { |i| i["type"] }

      expect(types).to eq(["message", "reasoning", "message"])
      reasoning = payload["input"][1]
      expect(reasoning["encrypted_content"]).to eq("encrypted_blob")
    end

    it "strips the content key from preserved reasoning items" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.user("Hello")
      session.add_item(PromptBuilder::Items::Reasoning.new(
        id: "rs_1",
        encrypted_content: "encrypted_blob",
        content: [{"type" => "reasoning_text", "text" => "Thinking..."}],
        summary: [{"type" => "summary_text", "text" => "Considered the request."}]
      ))
      session.assistant([PromptBuilder::Content::OutputText.new(text: "Hi!")])

      payload = described_class.request_payload(session)
      reasoning = payload["input"][1]

      expect(reasoning["type"]).to eq("reasoning")
      expect(reasoning["encrypted_content"]).to eq("encrypted_blob")
      expect(reasoning).not_to have_key("content")
      expect(reasoning["summary"]).to eq([{"type" => "summary_text", "text" => "Considered the request."}])
    end

    it "strips logprobs from output_text content blocks" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.user("Hello")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "assistant",
        content: [PromptBuilder::Content::OutputText.new(
          text: "Hi!",
          logprobs: [{"token" => "Hi", "logprob" => -0.1}],
          annotations: [{"type" => "url_citation", "url" => "https://example.com", "start_index" => 0, "end_index" => 2, "title" => "Example"}]
        )]
      ))

      payload = described_class.request_payload(session)
      content = payload["input"][1]["content"][0]

      expect(content["type"]).to eq("output_text")
      expect(content["text"]).to eq("Hi!")
      expect(content).not_to have_key("logprobs")
      expect(content["annotations"]).to be_a(Array)
    end

    it "flattens nested json_schema format to canonical Responses API shape" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.text = {
        "format" => {
          "type" => "json_schema",
          "json_schema" => {
            "name" => "response",
            "schema" => {"type" => "object", "properties" => {"answer" => {"type" => "string"}}, "required" => ["answer"]},
            "strict" => true
          }
        }
      }
      session.user("Hello")

      payload = described_class.request_payload(session)
      format = payload["text"]["format"]

      expect(format["type"]).to eq("json_schema")
      expect(format["name"]).to eq("response")
      expect(format["schema"]).to eq({"type" => "object", "properties" => {"answer" => {"type" => "string"}}, "required" => ["answer"]})
      expect(format["strict"]).to eq(true)
      expect(format).not_to have_key("json_schema")
    end

    it "preserves already-flat json_schema format" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.text = {
        "format" => {
          "type" => "json_schema",
          "name" => "response",
          "schema" => {"type" => "object", "properties" => {"answer" => {"type" => "string"}}, "required" => ["answer"]}
        }
      }
      session.user("Hello")

      payload = described_class.request_payload(session)
      format = payload["text"]["format"]

      expect(format["type"]).to eq("json_schema")
      expect(format["name"]).to eq("response")
      expect(format["schema"]).to eq({"type" => "object", "properties" => {"answer" => {"type" => "string"}}, "required" => ["answer"]})
    end
  end

  describe ".parse_response" do
    it "parses an Open Responses hash into PromptBuilder::Response" do
      hash = {
        "id" => "resp_123",
        "object" => "response",
        "status" => "completed",
        "model" => "gpt-5.2",
        "output" => [
          {
            "type" => "message",
            "role" => "assistant",
            "content" => [{"type" => "output_text", "text" => "Hello!"}]
          }
        ],
        "usage" => {
          "input_tokens" => 10,
          "output_tokens" => 5
        }
      }

      response = described_class.parse_response(hash)

      expect(response).to be_a(PromptBuilder::Response)
      expect(response.id).to eq("resp_123")
      expect(response.object).to eq("response")
      expect(response.status).to eq("completed")
      expect(response.model).to eq("gpt-5.2")
      expect(response.output.length).to eq(1)
      expect(response.output[0]).to be_a(PromptBuilder::Items::Message)
      expect(response.text).to eq("Hello!")
      expect(response.usage.input_tokens).to eq(10)
      expect(response.usage.output_tokens).to eq(5)
    end

    it "handles minimal response hashes" do
      response = described_class.parse_response({"object" => "response", "status" => "completed"})

      expect(response).to be_a(PromptBuilder::Response)
      expect(response.status).to eq("completed")
      expect(response.output).to eq([])
      expect(response.usage).to be_nil
    end

    it "round-trips RefusalContent through output" do
      hash = {
        "object" => "response",
        "status" => "completed",
        "output" => [{
          "type" => "message",
          "role" => "assistant",
          "content" => [{"type" => "refusal", "refusal" => "I cannot help."}]
        }]
      }

      response = described_class.parse_response(hash)
      msg = response.output[0]
      expect(msg).to be_a(PromptBuilder::Items::Message)
      expect(msg.content[0]).to be_a(PromptBuilder::Content::RefusalContent)
      expect(msg.content[0].refusal).to eq("I cannot help.")
    end

    it "round-trips InputVideo through session" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputVideo.new(url: "https://example.com/clip.mp4")]
      ))

      payload = described_class.request_payload(session)
      item_hash = payload["input"][0]
      expect(item_hash["type"]).to eq("message")
      expect(item_hash["content"][0]["type"]).to eq("input_video")
      expect(item_hash["content"][0]["video_url"]).to eq("https://example.com/clip.mp4")
    end

    it "round-trips ItemReference through session" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::ItemReference.new(id: "item_abc"))

      payload = described_class.request_payload(session)
      expect(payload["input"][0]).to eq({"type" => "item_reference", "id" => "item_abc"})
    end

    it "round-trips Compaction through response output" do
      hash = {
        "object" => "response",
        "status" => "completed",
        "output" => [{
          "type" => "compaction",
          "id" => "comp_1",
          "encrypted_content" => "encrypted_data",
          "created_by" => "assistant"
        }]
      }

      response = described_class.parse_response(hash)
      item = response.output[0]
      expect(item).to be_a(PromptBuilder::Items::Compaction)
      expect(item.id).to eq("comp_1")
      expect(item.encrypted_content).to eq("encrypted_data")
      expect(item.created_by).to eq("assistant")
    end
  end

  describe "schema validation" do
    schema_path = File.expand_path("../../open_responses_schema.json", __dir__)
    schema = JSON.parse(File.read(schema_path))
    fragment = "#/components/schemas/CreateResponseBody"

    it "produces a payload exercising every Open Responses feature that conforms to the OpenAPI schema" do
      session = PromptBuilder::Session.new(
        model: "gpt-5.4",
        instructions: "You are a helpful assistant.",
        temperature: 0.7,
        top_p: 0.9,
        presence_penalty: 0.1,
        frequency_penalty: 0.2,
        max_output_tokens: 1024,
        max_tool_calls: 4,
        top_logprobs: 5,
        parallel_tool_calls: true,
        stream: false,
        background: false,
        store: true,
        truncation: "auto",
        service_tier: "auto",
        safety_identifier: "user_42",
        prompt_cache_key: "cache_key_1",
        include: ["reasoning.encrypted_content", "message.output_text.logprobs"],
        tool_choice: "auto",
        metadata: {"session" => "abc", "tag" => "demo"},
        text: {"format" => {"type" => "text"}, "verbosity" => "medium"},
        stream_options: {"include_obfuscation" => true},
        reasoning: {"effort" => "medium", "summary" => "auto"}
      )

      session.register_tool(
        "get_weather",
        description: "Look up the weather for a city.",
        parameters: {
          "type" => "object",
          "properties" => {"city" => {"type" => "string"}},
          "required" => ["city"]
        },
        strict: true
      )

      session.system("Stay concise.")
      session.developer("Use metric units.")
      session.user([
        PromptBuilder::Content::InputText.new(text: "Describe these inputs."),
        PromptBuilder::Content::InputImage.new(url: "https://example.com/img.png", detail: "high"),
        PromptBuilder::Content::InputImage.new(extra: {"file_id" => "file_abc"}),
        PromptBuilder::Content::InputImage.new(url: "data:image/png;base64,aGVsbG8="),
        PromptBuilder::Content::InputFile.new(url: "https://example.com/doc.pdf", filename: "doc.pdf"),
        PromptBuilder::Content::InputFile.new(extra: {"file_id" => "file_xyz"}),
        PromptBuilder::Content::InputFile.new(url: "data:application/pdf;base64,aGVsbG8=", filename: "inline.pdf")
      ])

      session.add_item(PromptBuilder::Items::Reasoning.new(
        id: "rs_1",
        encrypted_content: "encrypted_reasoning_blob",
        summary: [{"type" => "summary_text", "text" => "Considered the request."}]
      ))

      session.assistant([
        PromptBuilder::Content::OutputText.new(text: "Here is the result."),
        PromptBuilder::Content::RefusalContent.new(refusal: "Cannot share private data.")
      ])

      session.add_item(PromptBuilder::Items::FunctionCall.new(
        id: "fc_1",
        call_id: "call_1",
        name: "get_weather",
        arguments: {"city" => "Paris"},
        status: "completed"
      ))

      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        id: "fco_1",
        call_id: "call_1",
        status: "completed",
        output: [
          PromptBuilder::Content::InputText.new(text: "Sunny, 22C"),
          PromptBuilder::Content::InputImage.new(url: "data:image/png;base64,aW1n"),
          PromptBuilder::Content::InputFile.new(url: "https://example.com/forecast.pdf"),
          PromptBuilder::Content::InputVideo.new(url: "https://example.com/clip.mp4")
        ]
      ))

      session.add_item(PromptBuilder::Items::Compaction.new(
        id: "cmp_1",
        encrypted_content: "compacted_blob"
      ))

      session.add_item(PromptBuilder::Items::ItemReference.new(id: "msg_prior_1"))

      payload = described_class.request_payload(session)
      errors = JSON::Validator.fully_validate(schema, payload, fragment: fragment)

      expect(errors).to be_empty, -> { "Payload failed schema validation:\n#{errors.join("\n")}\n\nPayload:\n#{JSON.pretty_generate(payload)}" }
    end

    it "rejects malformed payloads against the schema (sanity check)" do
      bad_payload = {
        "input" => [
          {"type" => "message", "role" => "alien", "content" => "hi"}
        ]
      }
      errors = JSON::Validator.fully_validate(schema, bad_payload, fragment: fragment)
      expect(errors).not_to be_empty
    end
  end
end
