# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Content::SummaryText do
  describe "#to_h" do
    it "serializes to a hash with type and text" do
      content = described_class.new(text: "Summary of reasoning")
      expect(content.to_h).to eq({"type" => "summary_text", "text" => "Summary of reasoning"})
    end
  end

  describe ".from_h" do
    it "deserializes from a hash" do
      content = described_class.from_h({"type" => "summary_text", "text" => "Summary of reasoning"})
      expect(content.text).to eq("Summary of reasoning")
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(text: "test summary")
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Content::Base.from_h" do
      content = PromptBuilder::Content::Base.from_h({"type" => "summary_text", "text" => "Summary"})
      expect(content).to be_a(described_class)
      expect(content.text).to eq("Summary")
    end
  end
end
