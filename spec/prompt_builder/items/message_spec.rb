# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Items::Message do
  describe "#to_h" do
    it "serializes a message with content" do
      message = described_class.new(
        id: "msg_123",
        role: "user",
        status: "completed",
        phase: "output",
        content: [PromptBuilder::Content::InputText.new(text: "Hello")]
      )
      expect(message.to_h).to eq({
        "type" => "message",
        "id" => "msg_123",
        "role" => "user",
        "status" => "completed",
        "phase" => "output",
        "content" => [{"type" => "input_text", "text" => "Hello"}]
      })
    end
  end

  describe ".from_h" do
    it "deserializes from a hash" do
      message = described_class.from_h({
        "type" => "message",
        "id" => "msg_123",
        "role" => "user",
        "status" => "completed",
        "phase" => "input",
        "content" => [{"type" => "input_text", "text" => "Hello"}]
      })
      expect(message.id).to eq("msg_123")
      expect(message.role).to eq("user")
      expect(message.status).to eq("completed")
      expect(message.phase).to eq("input")
      expect(message.content.length).to eq(1)
      expect(message.content[0]).to be_a(PromptBuilder::Content::InputText)
      expect(message.content[0].text).to eq("Hello")
    end
  end

  describe "content normalization" do
    it "wraps a string into InputText content" do
      message = described_class.new(role: "user", content: "Hello")
      expect(message.content.length).to eq(1)
      expect(message.content[0]).to be_a(PromptBuilder::Content::InputText)
      expect(message.content[0].text).to eq("Hello")
    end

    it "accepts an array of content objects" do
      content = [PromptBuilder::Content::InputText.new(text: "Hello")]
      message = described_class.new(role: "user", content: content)
      expect(message.content).to eq(content)
    end

    it "deserializes an array of hashes" do
      content = [{"type" => "input_text", "text" => "Hello"}]
      message = described_class.new(role: "user", content: content)
      expect(message.content[0]).to be_a(PromptBuilder::Content::InputText)
    end

    it "raises on unsupported content type" do
      expect {
        described_class.new(role: "user", content: 42)
      }.to raise_error(PromptBuilder::InvalidItemError)
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(role: "user", content: "Hello world")
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Items::Base.from_h" do
      item = PromptBuilder::Items::Base.from_h({
        "type" => "message",
        "role" => "user",
        "content" => [{"type" => "input_text", "text" => "Hello"}]
      })
      expect(item).to be_a(described_class)
    end
  end
end
