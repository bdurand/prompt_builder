# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Items::FunctionCall do
  let(:call) do
    described_class.new(
      name: "get_weather",
      call_id: "call_123",
      arguments: '{"city":"London"}',
      id: "fc_1",
      status: "completed"
    )
  end

  describe "#to_h" do
    it "serializes all fields" do
      expect(call.to_h).to eq({
        "type" => "function_call",
        "name" => "get_weather",
        "call_id" => "call_123",
        "arguments" => '{"city":"London"}',
        "id" => "fc_1",
        "status" => "completed"
      })
    end

    it "omits nil optional fields" do
      minimal = described_class.new(
        name: "get_weather",
        call_id: "call_123",
        arguments: "{}"
      )
      h = minimal.to_h
      expect(h).not_to have_key("id")
      expect(h).not_to have_key("status")
    end
  end

  describe ".from_h" do
    it "deserializes from a hash" do
      restored = described_class.from_h(call.to_h)
      expect(restored.name).to eq("get_weather")
      expect(restored.call_id).to eq("call_123")
      expect(restored.arguments).to eq('{"city":"London"}')
      expect(restored.id).to eq("fc_1")
      expect(restored.status).to eq("completed")
    end
  end

  describe "#parsed_arguments" do
    it "parses the JSON arguments string" do
      expect(call.parsed_arguments).to eq({"city" => "London"})
    end

    it "raises InvalidItemError for invalid JSON" do
      bad = described_class.new(name: "get_weather", call_id: "call_1", arguments: "not json")
      expect { bad.parsed_arguments }.to raise_error(PromptBuilder::InvalidItemError, /Invalid JSON.*get_weather/)
    end
  end

  describe "arguments coercion" do
    it "JSON-encodes a Hash passed as arguments" do
      call = described_class.new(name: "x", call_id: "c", arguments: {"city" => "London"})
      expect(call.arguments).to eq('{"city":"London"}')
      expect(call.parsed_arguments).to eq({"city" => "London"})
    end

    it "passes through a String as-is" do
      call = described_class.new(name: "x", call_id: "c", arguments: '{"a":1}')
      expect(call.arguments).to eq('{"a":1}')
    end

    it "defaults nil arguments to an empty JSON object" do
      call = described_class.new(name: "x", call_id: "c", arguments: nil)
      expect(call.arguments).to eq("{}")
      expect(call.parsed_arguments).to eq({})
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      restored = described_class.from_h(call.to_h)
      expect(restored.to_h).to eq(call.to_h)
    end
  end

  describe "polymorphic dispatch" do
    it "dispatches from Items::Base.from_h" do
      item = PromptBuilder::Items::Base.from_h({
        "type" => "function_call",
        "name" => "get_weather",
        "call_id" => "call_123",
        "arguments" => "{}"
      })
      expect(item).to be_a(described_class)
    end
  end
end
