# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Content::InputFile do
  describe "#to_h" do
    it "serializes with file_url" do
      content = described_class.new(file_url: "https://example.com/doc.pdf")
      expect(content.to_h).to eq({
        "type" => "input_file",
        "file_url" => "https://example.com/doc.pdf"
      })
    end

    it "serializes with base64 data and filename" do
      content = described_class.new(file_data: "abc123", filename: "doc.pdf")
      expect(content.to_h).to eq({
        "type" => "input_file",
        "file_data" => "abc123",
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
    it "deserializes from a hash" do
      content = described_class.from_h({
        "type" => "input_file",
        "file_url" => "https://example.com/doc.pdf",
        "file_data" => "abc",
        "filename" => "doc.pdf"
      })
      expect(content.file_url).to eq("https://example.com/doc.pdf")
      expect(content.file_data).to eq("abc")
      expect(content.filename).to eq("doc.pdf")
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(file_url: "https://example.com/doc.pdf", filename: "doc.pdf")
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Content::Base.from_h" do
      content = PromptBuilder::Content::Base.from_h({
        "type" => "input_file",
        "file_url" => "https://example.com/doc.pdf"
      })
      expect(content).to be_a(described_class)
    end
  end
end
