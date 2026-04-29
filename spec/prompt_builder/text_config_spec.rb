# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::TextConfig do
  describe ".from_h" do
    it "deserializes format and verbosity" do
      config = described_class.from_h({
        "format" => {"type" => "json_schema"},
        "verbosity" => "high"
      })

      expect(config.format).to eq({"type" => "json_schema"})
      expect(config.verbosity).to eq("high")
    end
  end

  describe "#to_h" do
    it "serializes format and verbosity" do
      config = described_class.new(format: {"type" => "json_schema"}, verbosity: "low")

      expect(config.to_h).to eq({
        "format" => {"type" => "json_schema"},
        "verbosity" => "low"
      })
    end
  end
end
