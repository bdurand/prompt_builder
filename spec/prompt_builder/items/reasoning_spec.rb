# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Items::Reasoning do
  describe "#to_h" do
    it "serializes with all fields" do
      reasoning = described_class.new(
        id: "rs_123",
        status: "completed",
        encrypted_content: "enc_456",
        summary: [{"type" => "text", "text" => "I thought about it."}],
        content: [{"type" => "text", "text" => "Step 1..."}]
      )
      expect(reasoning.to_h).to eq({
        "type" => "reasoning",
        "id" => "rs_123",
        "status" => "completed",
        "encrypted_content" => "enc_456",
        "summary" => [{"type" => "text", "text" => "I thought about it."}],
        "content" => [{"type" => "text", "text" => "Step 1..."}]
      })
    end

    it "omits nil and empty fields" do
      reasoning = described_class.new
      expect(reasoning.to_h).to eq({"type" => "reasoning"})
    end
  end

  describe ".from_h" do
    it "deserializes from a hash" do
      reasoning = described_class.from_h({
        "type" => "reasoning",
        "id" => "rs_123",
        "status" => "completed",
        "encrypted_content" => "enc_456",
        "summary" => [{"type" => "text", "text" => "Summary"}],
        "content" => [{"type" => "text", "text" => "Content"}]
      })
      expect(reasoning.id).to eq("rs_123")
      expect(reasoning.status).to eq("completed")
      expect(reasoning.encrypted_content).to eq("enc_456")
      expect(reasoning.summary).to eq([{"type" => "text", "text" => "Summary"}])
      expect(reasoning.content).to eq([{"type" => "text", "text" => "Content"}])
    end

    it "defaults summary and content to empty arrays" do
      reasoning = described_class.from_h({"type" => "reasoning"})
      expect(reasoning.summary).to eq([])
      expect(reasoning.content).to eq([])
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(
        status: "completed",
        content: [{"type" => "text", "text" => "thinking"}]
      )
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Items::Base.from_h" do
      item = PromptBuilder::Items::Base.from_h({"type" => "reasoning"})
      expect(item).to be_a(described_class)
    end
  end
end
