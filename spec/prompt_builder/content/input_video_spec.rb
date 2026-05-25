# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Content::InputVideo do
  describe "#to_h" do
    it "serializes with url" do
      content = described_class.new(url: "https://example.com/video.mp4")
      expect(content.to_h).to eq({
        "type" => "input_video",
        "url" => "https://example.com/video.mp4"
      })
    end

    it "omits nil url" do
      content = described_class.new
      expect(content.to_h).to eq({"type" => "input_video"})
    end
  end

  describe ".from_h" do
    it "deserializes from a hash with url" do
      content = described_class.from_h({
        "type" => "input_video",
        "url" => "https://example.com/video.mp4"
      })
      expect(content.url).to eq("https://example.com/video.mp4")
    end

    it "handles missing url" do
      content = described_class.from_h({"type" => "input_video"})
      expect(content.url).to be_nil
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(url: "https://example.com/video.mp4")
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Content::Base.from_h" do
      content = PromptBuilder::Content::Base.from_h({
        "type" => "input_video",
        "url" => "https://example.com/clip.mp4"
      })
      expect(content).to be_a(described_class)
      expect(content.url).to eq("https://example.com/clip.mp4")
    end
  end
end
