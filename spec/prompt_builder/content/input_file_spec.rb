# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Content::InputFile do
  describe "#to_h" do
    it "serializes with url" do
      content = described_class.new(url: "https://example.com/doc.pdf")
      expect(content.to_h).to eq({
        "type" => "input_file",
        "url" => "https://example.com/doc.pdf"
      })
    end

    it "serializes with base64 data and filename" do
      content = described_class.new(url: "data:application/octet-stream;base64,abc123", filename: "doc.pdf")
      expect(content.to_h).to eq({
        "type" => "input_file",
        "url" => "data:application/octet-stream;base64,abc123",
        "filename" => "doc.pdf"
      })
    end

    it "omits nil values" do
      content = described_class.new
      expect(content.to_h).to eq({"type" => "input_file"})
    end

    it "supports extra passed as an extra: hash" do
      content = described_class.new(extra: {"file_id" => "file_abc"})

      expect(content.to_h).to eq({
        "type" => "input_file",
        "file_id" => "file_abc"
      })
    end
  end

  describe ".from_h" do
    it "deserializes from a hash with url" do
      content = described_class.from_h({
        "type" => "input_file",
        "url" => "https://example.com/doc.pdf",
        "filename" => "doc.pdf"
      })
      expect(content.url).to eq("https://example.com/doc.pdf")
      expect(content.filename).to eq("doc.pdf")
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(url: "https://example.com/doc.pdf", filename: "doc.pdf")
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Content::Base.from_h" do
      content = PromptBuilder::Content::Base.from_h({
        "type" => "input_file",
        "url" => "https://example.com/doc.pdf"
      })
      expect(content).to be_a(described_class)
    end
  end

  describe "#data" do
    it "returns decoded binary data from a data URL" do
      url = PromptBuilder::Content.data_url("hello world", "text/plain")
      content = described_class.new(url: url)
      parsed = PromptBuilder.parse_data_url(content.url)
      expect(parsed[0]).to eq("text/plain")
      expect(parsed[1].unpack1("m0")).to eq("hello world")
    end

    it "returns nil for a non-data URL" do
      content = described_class.new(url: "https://example.com/doc.pdf")
      parsed = PromptBuilder.parse_data_url(content.url)
      expect(parsed).to be_nil
    end
  end
end
