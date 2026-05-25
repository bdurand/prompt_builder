# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Content::InputImage do
  describe "#to_h" do
    it "serializes with url" do
      content = described_class.new(url: "https://example.com/img.png")
      expect(content.to_h).to eq({
        "type" => "input_image",
        "url" => "https://example.com/img.png"
      })
    end

    it "serializes with base64 data URL" do
      content = described_class.new(url: "data:image/png;base64,abc123", detail: "high")
      expect(content.to_h).to eq({
        "type" => "input_image",
        "url" => "data:image/png;base64,abc123",
        "detail" => "high"
      })
    end

    it "omits nil values" do
      content = described_class.new
      expect(content.to_h).to eq({"type" => "input_image"})
    end

    it "supports extra passed as an extra: hash" do
      content = described_class.new(extra: {"file_id" => "file_abc"})

      expect(content.to_h).to eq({
        "type" => "input_image",
        "file_id" => "file_abc"
      })
    end
  end

  describe ".from_h" do
    it "deserializes from a hash with url" do
      content = described_class.from_h({
        "type" => "input_image",
        "url" => "https://example.com/img.png",
        "detail" => "auto",
        "file_id" => "file-abc"
      })
      expect(content.url).to eq("https://example.com/img.png")
      expect(content.detail).to eq("auto")
      expect(content.extra).to eq({"file_id" => "file-abc"})
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(url: "https://example.com/img.png")
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Content::Base.from_h" do
      content = PromptBuilder::Content::Base.from_h({
        "type" => "input_image",
        "url" => "https://example.com/img.png"
      })
      expect(content).to be_a(described_class)
    end
  end

  describe "#data" do
    it "returns decoded binary data from a data URL" do
      url = PromptBuilder::Content.data_url("\x89PNG\r\n".b, "image/png")
      content = described_class.new(url: url)
      parsed = PromptBuilder.parse_data_url(content.url)
      expect(parsed[0]).to eq("image/png")
      expect(parsed[1].unpack1("m0")).to eq("\x89PNG\r\n".b)
    end

    it "returns nil for a non-data URL" do
      content = described_class.new(url: "https://example.com/img.png")
      parsed = PromptBuilder.parse_data_url(content.url)
      expect(parsed).to be_nil
    end
  end
end
