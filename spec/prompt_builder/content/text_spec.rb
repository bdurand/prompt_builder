# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Content::Text do
  describe "#to_h" do
    it "serializes to a hash with type and text" do
      content = described_class.new(text: "Hello")
      expect(content.to_h).to eq({"type" => "text", "text" => "Hello"})
    end
  end

  describe ".from_h" do
    it "deserializes from a hash" do
      content = described_class.from_h({"type" => "text", "text" => "Hello"})
      expect(content.text).to eq("Hello")
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(text: "test text")
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Content::Base.from_h" do
      content = PromptBuilder::Content::Base.from_h({"type" => "text", "text" => "Hello"})
      expect(content).to be_a(described_class)
      expect(content.text).to eq("Hello")
    end
  end
end
