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

    it "serializes with base64 data" do
      content = described_class.new(data: "abc123", media_type: "image/png", detail: "high")
      expect(content.to_h).to eq({
        "type" => "input_image",
        "data" => "abc123",
        "media_type" => "image/png",
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
        "data" => "abc",
        "media_type" => "image/png",
        "detail" => "auto"
      })
      expect(content.image_url).to eq("https://example.com/img.png")
      expect(content.data).to eq("abc")
      expect(content.media_type).to eq("image/png")
      expect(content.detail).to eq("auto")
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
