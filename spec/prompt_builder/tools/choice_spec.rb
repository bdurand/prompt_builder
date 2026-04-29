# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Tools::Choice do
  describe "#auto?" do
    it "returns true for auto" do
      expect(described_class.new(value: "auto")).to be_auto
    end

    it "returns false for other values" do
      expect(described_class.new(value: "required")).not_to be_auto
    end
  end

  describe "#required?" do
    it "returns true for required" do
      expect(described_class.new(value: "required")).to be_required
    end
  end

  describe "#none?" do
    it "returns true for none" do
      expect(described_class.new(value: "none")).to be_none
    end
  end

  describe "#specific_function?" do
    it "returns true for a function hash" do
      choice = described_class.new(value: {"type" => "function", "name" => "get_weather"})
      expect(choice).to be_specific_function
    end

    it "returns false for a string value" do
      expect(described_class.new(value: "auto")).not_to be_specific_function
    end
  end

  describe "#allowed_tools?" do
    it "returns true for an allowed_tools hash" do
      choice = described_class.new(value: {"type" => "allowed_tools", "tools" => ["search"], "mode" => "auto"})
      expect(choice).to be_allowed_tools
    end

    it "returns false for a string value" do
      expect(described_class.new(value: "auto")).not_to be_allowed_tools
    end

    it "returns false for a function hash" do
      choice = described_class.new(value: {"type" => "function", "name" => "get_weather"})
      expect(choice).not_to be_allowed_tools
    end
  end

  describe "#function_name" do
    it "returns the function name for a specific function choice" do
      choice = described_class.new(value: {"type" => "function", "name" => "get_weather"})
      expect(choice.function_name).to eq("get_weather")
    end

    it "returns nil for a non-specific choice" do
      expect(described_class.new(value: "auto").function_name).to be_nil
    end
  end

  describe "#allowed_tools" do
    it "returns the tools array for an allowed_tools choice" do
      choice = described_class.new(value: {"type" => "allowed_tools", "tools" => ["search", "calc"], "mode" => "auto"})
      expect(choice.allowed_tools).to eq(["search", "calc"])
    end

    it "returns nil for a non-allowed_tools choice" do
      expect(described_class.new(value: "auto").allowed_tools).to be_nil
    end
  end

  describe "#mode" do
    it "returns the mode for an allowed_tools choice" do
      choice = described_class.new(value: {"type" => "allowed_tools", "tools" => [], "mode" => "auto"})
      expect(choice.mode).to eq("auto")
    end

    it "returns nil for a string choice" do
      expect(described_class.new(value: "auto").mode).to be_nil
    end

    it "returns nil when mode is not set in hash" do
      choice = described_class.new(value: {"type" => "function", "name" => "foo"})
      expect(choice.mode).to be_nil
    end
  end

  describe "#to_h" do
    it "returns the raw value" do
      expect(described_class.new(value: "auto").to_h).to eq("auto")
    end

    it "returns the hash value for specific function" do
      value = {"type" => "function", "name" => "get_weather"}
      expect(described_class.new(value: value).to_h).to eq(value)
    end
  end

  describe ".from_h" do
    it "creates a choice from a raw value" do
      choice = described_class.from_h("auto")
      expect(choice.value).to eq("auto")
    end
  end
end
