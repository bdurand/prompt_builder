# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Items::ItemReference do
  describe "#to_h" do
    it "serializes to a hash with type and id" do
      item = described_class.new(id: "msg_abc123")
      expect(item.to_h).to eq({
        "type" => "item_reference",
        "id" => "msg_abc123"
      })
    end
  end

  describe ".from_h" do
    it "deserializes from a hash" do
      item = described_class.from_h({
        "type" => "item_reference",
        "id" => "msg_abc123"
      })
      expect(item.id).to eq("msg_abc123")
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(id: "msg_xyz")
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Items::Base.from_h" do
      item = PromptBuilder::Items::Base.from_h({"type" => "item_reference", "id" => "ref_001"})
      expect(item).to be_a(described_class)
      expect(item.id).to eq("ref_001")
    end
  end
end
