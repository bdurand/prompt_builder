# frozen_string_literal: true

require "spec_helper"

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

    it "passes through InputImage with image_url unchanged" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(image_url: "https://example.com/img.png")]
      ))

      payload = described_class.request_payload(session)
      content = payload["input"][0]["content"][0]

      expect(content["type"]).to eq("input_image")
      expect(content["image_url"]).to eq("https://example.com/img.png")
      expect(content).not_to have_key("data")
      expect(content).not_to have_key("media_type")
    end

    it "converts InputImage with base64 data into a data URL for image_url" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(data: "abc123", media_type: "image/png")]
      ))

      payload = described_class.request_payload(session)
      content = payload["input"][0]["content"][0]

      expect(content["type"]).to eq("input_image")
      expect(content["image_url"]).to eq("data:image/png;base64,abc123")
      expect(content).not_to have_key("data")
      expect(content).not_to have_key("media_type")
    end

    it "strips canonical-only data/media_type keys when image_url is also set" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(
          image_url: "https://example.com/img.png",
          data: "abc123",
          media_type: "image/png"
        )]
      ))

      payload = described_class.request_payload(session)
      content = payload["input"][0]["content"][0]

      expect(content["image_url"]).to eq("https://example.com/img.png")
      expect(content).not_to have_key("data")
      expect(content).not_to have_key("media_type")
    end

    it "raises when InputImage has only base64 data without media_type" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(data: "abc")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /InputImage\.media_type/)
    end

    it "raises when InputImage has neither image_url, file_id, nor data" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::Message.new(
        role: "user",
        content: [PromptBuilder::Content::InputImage.new(media_type: "image/png")]
      ))

      expect {
        described_class.request_payload(session)
      }.to raise_error(PromptBuilder::UnsupportedFormatError, /image_url, InputImage\.file_id, or InputImage\.data/)
    end

    it "transforms base64 InputImage inside FunctionCallOutput content" do
      session = PromptBuilder::Session.new(model: "gpt-5.4")
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(
        call_id: "c1",
        output: [PromptBuilder::Content::InputImage.new(data: "abc", media_type: "image/png")]
      ))

      payload = described_class.request_payload(session)
      content = payload["input"][0]["output"][0]

      expect(content["image_url"]).to eq("data:image/png;base64,abc")
      expect(content).not_to have_key("data")
      expect(content).not_to have_key("media_type")
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
      response = described_class.parse_response({"status" => "completed"})

      expect(response).to be_a(PromptBuilder::Response)
      expect(response.status).to eq("completed")
      expect(response.output).to eq([])
      expect(response.usage).to be_nil
    end

    it "round-trips RefusalContent through output" do
      hash = {
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
        content: [PromptBuilder::Content::InputVideo.new(video_url: "https://example.com/clip.mp4")]
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
end
