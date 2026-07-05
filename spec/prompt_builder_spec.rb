# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder do
  describe "VERSION" do
    it "has a version number" do
      expect(PromptBuilder::VERSION).to eq(File.read(File.join(__dir__, "../VERSION")).strip)
    end
  end

  describe ".data_url" do
    it "constructs a base64-encoded data URL" do
      url = described_class.data_url("hello world", "text/plain")
      expect(url).to eq("data:text/plain;base64,aGVsbG8gd29ybGQ=")
    end

    it "handles binary data" do
      data = "\x89PNG\r\n\x1A\n".b
      url = described_class.data_url(data, "image/png")
      parsed = PromptBuilder.parse_data_url(url)
      expect(parsed[0]).to eq("image/png")
      expect(parsed[1].unpack1("m0")).to eq(data)
    end
  end

  describe ".parse_data_url" do
    it "parses a simple base64 data URL" do
      parsed = described_class.parse_data_url("data:text/plain;base64,aGVsbG8=")
      expect(parsed).to eq(["text/plain", "aGVsbG8="])
    end

    it "parses a data URL with media type parameters" do
      parsed = described_class.parse_data_url("data:text/plain;charset=utf-8;base64,aGVsbG8=")
      expect(parsed).to eq(["text/plain", "aGVsbG8="])
    end

    it "parses a data URL with multiple media type parameters" do
      parsed = described_class.parse_data_url("data:text/plain;charset=utf-8;format=fixed;base64,aGVsbG8=")
      expect(parsed).to eq(["text/plain", "aGVsbG8="])
    end

    it "returns nil for non-base64 data URLs" do
      expect(described_class.parse_data_url("data:text/plain,hello")).to be_nil
    end

    it "returns nil for regular URLs and nil input" do
      expect(described_class.parse_data_url("https://example.com/file.png")).to be_nil
      expect(described_class.parse_data_url(nil)).to be_nil
    end
  end
end
