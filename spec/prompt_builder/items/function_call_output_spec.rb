# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Items::FunctionCallOutput do
  describe "#to_h" do
    it "serializes to a hash" do
      output = described_class.new(id: "fco_123", call_id: "call_123", status: "completed", output: "72F sunny")
      expect(output.to_h).to eq({
        "type" => "function_call_output",
        "id" => "fco_123",
        "call_id" => "call_123",
        "status" => "completed",
        "output" => "72F sunny"
      })
    end

    it "serializes array output as an array of content hashes" do
      output = described_class.new(
        call_id: "call_123",
        output: [PromptBuilder::Content::OutputText.new(text: "72F sunny")]
      )
      expect(output.to_h).to eq({
        "type" => "function_call_output",
        "call_id" => "call_123",
        "output" => [{"type" => "output_text", "text" => "72F sunny"}]
      })
    end
  end

  describe ".from_h" do
    it "deserializes from a hash" do
      output = described_class.from_h({
        "type" => "function_call_output",
        "id" => "fco_123",
        "call_id" => "call_123",
        "status" => "completed",
        "output" => "72F sunny"
      })
      expect(output.id).to eq("fco_123")
      expect(output.call_id).to eq("call_123")
      expect(output.status).to eq("completed")
      expect(output.output).to eq("72F sunny")
    end

    it "deserializes array output into content objects" do
      output = described_class.from_h({
        "type" => "function_call_output",
        "call_id" => "call_123",
        "output" => [{"type" => "output_text", "text" => "72F sunny"}]
      })
      expect(output.output).to be_an(Array)
      expect(output.output.length).to eq(1)
      expect(output.output[0]).to be_a(PromptBuilder::Content::OutputText)
      expect(output.output[0].text).to eq("72F sunny")
    end
  end

  describe "array output normalization" do
    it "accepts Content::Base objects directly" do
      content = PromptBuilder::Content::InputText.new(text: "hello")
      output = described_class.new(call_id: "call_1", output: [content])
      expect(output.output).to eq([content])
    end

    it "normalizes Hash elements to content objects" do
      output = described_class.new(
        call_id: "call_1",
        output: [{"type" => "input_text", "text" => "hello"}]
      )
      expect(output.output[0]).to be_a(PromptBuilder::Content::InputText)
    end

    it "raises for unsupported output element types" do
      expect {
        described_class.new(call_id: "call_1", output: [42])
      }.to raise_error(PromptBuilder::InvalidItemError, /Unsupported output element/)
    end

    it "raises for unsupported output types" do
      expect {
        described_class.new(call_id: "call_1", output: 123)
      }.to raise_error(PromptBuilder::InvalidItemError, /Unsupported output type/)
    end
  end

  describe "round-trip" do
    it "round-trips string output through to_h and from_h" do
      original = described_class.new(call_id: "call_123", output: "result")
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end

    it "round-trips array output through to_h and from_h" do
      original = described_class.new(
        call_id: "call_123",
        output: [PromptBuilder::Content::OutputText.new(text: "result")]
      )
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Items::Base.from_h" do
      item = PromptBuilder::Items::Base.from_h({
        "type" => "function_call_output",
        "call_id" => "call_123",
        "output" => "result"
      })
      expect(item).to be_a(described_class)
    end
  end
end
