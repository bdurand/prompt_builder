# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Items::Compaction do
  describe "#to_h" do
    it "serializes with all fields" do
      item = described_class.new(
        id: "cmp_123",
        encrypted_content: "enc_abc",
        created_by: "assistant"
      )
      expect(item.to_h).to eq({
        "type" => "compaction",
        "id" => "cmp_123",
        "encrypted_content" => "enc_abc",
        "created_by" => "assistant"
      })
    end

    it "omits nil fields" do
      item = described_class.new
      expect(item.to_h).to eq({"type" => "compaction"})
    end
  end

  describe ".from_h" do
    it "deserializes from a hash" do
      item = described_class.from_h({
        "type" => "compaction",
        "id" => "cmp_123",
        "encrypted_content" => "enc_abc",
        "created_by" => "assistant"
      })
      expect(item.id).to eq("cmp_123")
      expect(item.encrypted_content).to eq("enc_abc")
      expect(item.created_by).to eq("assistant")
    end

    it "handles missing optional fields" do
      item = described_class.from_h({"type" => "compaction"})
      expect(item.id).to be_nil
      expect(item.encrypted_content).to be_nil
      expect(item.created_by).to be_nil
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(id: "cmp_1", encrypted_content: "enc_x", created_by: "user")
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Items::Base.from_h" do
      item = PromptBuilder::Items::Base.from_h({"type" => "compaction", "id" => "cmp_456"})
      expect(item).to be_a(described_class)
      expect(item.id).to eq("cmp_456")
    end
  end
end
