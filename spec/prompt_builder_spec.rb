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
end
