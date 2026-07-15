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

    it "wraps a single Content::Base object into an array" do
      content = PromptBuilder::Content::InputText.new(text: "Hello")
      message = described_class.new(role: "user", content: content)
      expect(message.content.length).to eq(1)
      expect(message.content[0]).to be(content)
    end

    it "wraps a single Hash with string keys into content" do
      message = described_class.new(role: "user", content: {"type" => "input_text", "text" => "Hello"})
      expect(message.content.length).to eq(1)
      expect(message.content[0]).to be_a(PromptBuilder::Content::InputText)
      expect(message.content[0].text).to eq("Hello")
    end

    it "wraps a single Hash with symbol keys into content" do
      message = described_class.new(role: "user", content: {type: "input_text", text: "Hello"})
      expect(message.content.length).to eq(1)
      expect(message.content[0]).to be_a(PromptBuilder::Content::InputText)
      expect(message.content[0].text).to eq("Hello")
    end

    it "accepts an array of content objects" do
      content = [PromptBuilder::Content::InputText.new(text: "Hello")]
      message = described_class.new(role: "user", content: content)
      expect(message.content).to eq(content)
    end

    it "deserializes an array of hashes with string keys" do
      content = [{"type" => "input_text", "text" => "Hello"}]
      message = described_class.new(role: "user", content: content)
      expect(message.content[0]).to be_a(PromptBuilder::Content::InputText)
    end

    it "deserializes an array of hashes with symbol keys" do
      content = [{type: "input_text", text: "Hello"}]
      message = described_class.new(role: "user", content: content)
      expect(message.content[0]).to be_a(PromptBuilder::Content::InputText)
      expect(message.content[0].text).to eq("Hello")
    end

    it "raises on unsupported content type" do
      expect {
        described_class.new(role: "user", content: 42)
      }.to raise_error(PromptBuilder::InvalidItemError)
    end
  end

  describe "message roles" do
    it "creates a user message with a Content::Base object" do
      content = PromptBuilder::Content::InputText.new(text: "user text")
      message = described_class.new(role: "user", content: content)
      expect(message.role).to eq("user")
      expect(message.content[0].text).to eq("user text")
    end

    it "creates an assistant message with a Content::Base object" do
      content = PromptBuilder::Content::OutputText.new(text: "assistant text")
      message = described_class.new(role: "assistant", content: content)
      expect(message.role).to eq("assistant")
      expect(message.content[0].text).to eq("assistant text")
    end

    it "creates a system message with a Content::Base object" do
      content = PromptBuilder::Content::InputText.new(text: "system text")
      message = described_class.new(role: "system", content: content)
      expect(message.role).to eq("system")
      expect(message.content[0].text).to eq("system text")
    end

    it "creates a developer message with a Content::Base object" do
      content = PromptBuilder::Content::InputText.new(text: "developer text")
      message = described_class.new(role: "developer", content: content)
      expect(message.role).to eq("developer")
      expect(message.content[0].text).to eq("developer text")
    end

    it "creates a user message with a Hash" do
      message = described_class.new(role: "user", content: {type: "input_text", text: "user hash"})
      expect(message.role).to eq("user")
      expect(message.content[0]).to be_a(PromptBuilder::Content::InputText)
      expect(message.content[0].text).to eq("user hash")
    end

    it "creates an assistant message with a Hash" do
      message = described_class.new(role: "assistant", content: {type: "output_text", text: "assistant hash"})
      expect(message.role).to eq("assistant")
      expect(message.content[0]).to be_a(PromptBuilder::Content::OutputText)
      expect(message.content[0].text).to eq("assistant hash")
    end

    it "creates a system message with a Hash" do
      message = described_class.new(role: "system", content: {type: "input_text", text: "system hash"})
      expect(message.role).to eq("system")
      expect(message.content[0]).to be_a(PromptBuilder::Content::InputText)
      expect(message.content[0].text).to eq("system hash")
    end

    it "creates a developer message with a Hash" do
      message = described_class.new(role: "developer", content: {type: "input_text", text: "developer hash"})
      expect(message.role).to eq("developer")
      expect(message.content[0]).to be_a(PromptBuilder::Content::InputText)
      expect(message.content[0].text).to eq("developer hash")
    end
  end

  describe "role predicates" do
    it "#system? is true only for a system message" do
      expect(described_class.new(role: "system", content: "x").system?).to be(true)
      expect(described_class.new(role: "user", content: "x").system?).to be(false)
    end

    it "#user? is true only for a user message" do
      expect(described_class.new(role: "user", content: "x").user?).to be(true)
      expect(described_class.new(role: "assistant", content: "x").user?).to be(false)
    end

    it "#assistant? is true only for an assistant message" do
      expect(described_class.new(role: "assistant", content: "x").assistant?).to be(true)
      expect(described_class.new(role: "user", content: "x").assistant?).to be(false)
    end

    it "returns false for all three predicates on a developer message" do
      message = described_class.new(role: "developer", content: "x")
      expect(message.system?).to be(false)
      expect(message.user?).to be(false)
      expect(message.assistant?).to be(false)
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
