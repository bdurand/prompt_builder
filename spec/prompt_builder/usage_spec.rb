# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Usage do
  describe ".from_h" do
    it "deserializes Open Responses usage fields" do
      usage = described_class.from_h({
        "input_tokens" => 10,
        "output_tokens" => 5,
        "total_tokens" => 15,
        "input_tokens_details" => {"cached_tokens" => 2},
        "output_tokens_details" => {"reasoning_tokens" => 3}
      })

      expect(usage.input_tokens).to eq(10)
      expect(usage.output_tokens).to eq(5)
      expect(usage.total_tokens).to eq(15)
      expect(usage.cached_tokens).to eq(2)
      expect(usage.reasoning_tokens).to eq(3)
    end

    it "preserves anthropic compatibility fields" do
      usage = described_class.from_h({
        "input_tokens" => 10,
        "output_tokens" => 5,
        "input_tokens_details" => {
          "cache_creation_input_tokens" => 1,
          "cached_tokens" => 4
        },
        "reasoning_tokens" => 3
      })

      expect(usage.cache_creation_input_tokens).to eq(1)
      expect(usage.cached_tokens).to eq(4)
      expect(usage.reasoning_tokens).to eq(3)
      expect(usage.to_h["output_tokens_details"]).to eq({"reasoning_tokens" => 3})
    end
  end

  describe "#to_h" do
    it "serializes spec usage fields" do
      usage = described_class.new(
        input_tokens: 10,
        output_tokens: 5,
        total_tokens: 15,
        input_tokens_details: {"cached_tokens" => 2},
        output_tokens_details: {"reasoning_tokens" => 3}
      )

      expect(usage.to_h).to eq({
        "input_tokens" => 10,
        "output_tokens" => 5,
        "total_tokens" => 15,
        "input_tokens_details" => {"cached_tokens" => 2},
        "output_tokens_details" => {"reasoning_tokens" => 3}
      })
    end
  end
end
