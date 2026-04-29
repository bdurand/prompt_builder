# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Tools::Definition do
  describe "#to_h" do
    it "serializes with all fields" do
      defn = described_class.new(
        name: "get_weather",
        description: "Get the weather",
        parameters: {"type" => "object", "properties" => {"city" => {"type" => "string"}}},
        strict: true
      )
      expect(defn.to_h).to eq({
        "type" => "function",
        "name" => "get_weather",
        "description" => "Get the weather",
        "parameters" => {"type" => "object", "properties" => {"city" => {"type" => "string"}}},
        "strict" => true
      })
    end

    it "omits nil and false optional fields" do
      defn = described_class.new(name: "test")
      h = defn.to_h
      expect(h).to eq({"type" => "function", "name" => "test"})
      expect(h).not_to have_key("description")
      expect(h).not_to have_key("parameters")
      expect(h).not_to have_key("strict")
    end
  end

  describe ".from_h" do
    it "deserializes from a hash" do
      defn = described_class.from_h({
        "name" => "get_weather",
        "description" => "Get the weather",
        "parameters" => {"type" => "object"},
        "strict" => true
      })
      expect(defn.name).to eq("get_weather")
      expect(defn.description).to eq("Get the weather")
      expect(defn.parameters).to eq({"type" => "object"})
      expect(defn.strict).to be true
    end

    it "defaults strict to false" do
      defn = described_class.from_h({"name" => "test"})
      expect(defn.strict).to be false
    end
  end

  describe "round-trip" do
    it "round-trips through to_h and from_h" do
      original = described_class.new(
        name: "test",
        description: "A test tool",
        parameters: {"type" => "object"},
        strict: true
      )
      restored = described_class.from_h(original.to_h)
      expect(restored.to_h).to eq(original.to_h)
    end
  end
end
