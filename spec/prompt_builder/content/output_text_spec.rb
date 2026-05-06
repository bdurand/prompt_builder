# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Content::OutputText do
  describe "#to_h" do
    it "serializes with text" do
      content = described_class.new(text: "Hello!")
      expect(content.to_h).to eq({"type" => "output_text", "text" => "Hello!"})
    end

    it "includes annotations when present" do
      annotations = [{"type" => "url", "url" => "https://example.com"}]
      logprobs = [{"token" => "Hello", "logprob" => -0.1}]
      content = described_class.new(
        text: "Hello!",
        annotations: annotations,
        logprobs: logprobs,
        thought_signature: "sig_123"
      )
      expect(content.to_h).to eq({
        "type" => "output_text",
        "text" => "Hello!",
        "annotations" => annotations,
        "logprobs" => logprobs,
        "thought_signature" => "sig_123"
      })
    end

    it "omits annotations when empty" do
      content = described_class.new(text: "Hello!", annotations: [])
      expect(content.to_h).not_to have_key("annotations")
    end
  end

  describe ".from_h" do
    it "deserializes from a hash" do
      content = described_class.from_h({"type" => "output_text", "text" => "Hello!"})
      expect(content.text).to eq("Hello!")
      expect(content.annotations).to eq([])
      expect(content.logprobs).to eq([])
    end

    it "deserializes annotations" do
      annotations = [{"type" => "url", "url" => "https://example.com"}]
      content = described_class.from_h({
        "type" => "output_text",
        "text" => "Hello!",
        "annotations" => annotations,
        "logprobs" => [{"token" => "Hello", "logprob" => -0.1}],
        "thought_signature" => "sig_123"
      })
      expect(content.annotations).to eq(annotations)
      expect(content.logprobs).to eq([{"token" => "Hello", "logprob" => -0.1}])
      expect(content.extra).to eq({"thought_signature" => "sig_123"})
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(text: "test", annotations: [{"type" => "url"}])
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Content::Base.from_h" do
      content = PromptBuilder::Content::Base.from_h({"type" => "output_text", "text" => "Hi"})
      expect(content).to be_a(described_class)
    end
  end
end
