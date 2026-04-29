# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Content::RefusalContent do
  describe "#to_h" do
    it "serializes to a hash with type and refusal" do
      content = described_class.new(refusal: "I cannot help with that.")
      expect(content.to_h).to eq({
        "type" => "refusal",
        "refusal" => "I cannot help with that."
      })
    end
  end

  describe ".from_h" do
    it "deserializes from a hash" do
      content = described_class.from_h({
        "type" => "refusal",
        "refusal" => "This request is not allowed."
      })
      expect(content.refusal).to eq("This request is not allowed.")
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(refusal: "Not allowed.")
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Content::Base.from_h" do
      content = PromptBuilder::Content::Base.from_h({"type" => "refusal", "refusal" => "No."})
      expect(content).to be_a(described_class)
      expect(content.refusal).to eq("No.")
    end
  end
end
