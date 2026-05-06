# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Content::InputImage do
  describe "#to_h" do
    it "serializes with image_url" do
      content = described_class.new(image_url: "https://example.com/img.png")
      expect(content.to_h).to eq({
        "type" => "input_image",
        "image_url" => "https://example.com/img.png"
      })
    end

    it "serializes with base64 data URL" do
      content = described_class.new(image_url: "data:image/png;base64,abc123", detail: "high")
      expect(content.to_h).to eq({
        "type" => "input_image",
        "image_url" => "data:image/png;base64,abc123",
        "detail" => "high"
      })
    end

    it "omits nil values" do
      content = described_class.new
      expect(content.to_h).to eq({"type" => "input_image"})
    end
  end

  describe ".from_h" do
    it "deserializes from a hash" do
      content = described_class.from_h({
        "type" => "input_image",
        "image_url" => "https://example.com/img.png",
        "detail" => "auto",
        "file_id" => "file-abc"
      })
      expect(content.image_url).to eq("https://example.com/img.png")
      expect(content.detail).to eq("auto")
      expect(content.extra).to eq({"file_id" => "file-abc"})
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(image_url: "https://example.com/img.png")
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Content::Base.from_h" do
      content = PromptBuilder::Content::Base.from_h({
        "type" => "input_image",
        "image_url" => "https://example.com/img.png"
      })
      expect(content).to be_a(described_class)
    end
  end
end
