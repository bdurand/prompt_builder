# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::ToolRegistry do
  let(:registry) { described_class.new }

  describe "#register" do
    it "registers a tool with a block handler" do
      registry.register("greet", description: "Say hello") { |args| "Hello, #{args["name"]}!" }
      expect(registry.definition_for("greet")).not_to be_nil
      expect(registry.definition_for("greet").name).to eq("greet")
      expect(registry.definition_for("greet").description).to eq("Say hello")
    end

    it "registers a tool with a callable handler" do
      handler = ->(args) { "Hello, #{args["name"]}!" }
      registry.register("greet", callable: handler)
      expect(registry.handler_for("greet")).to eq(handler)
    end
  end

  describe "#handler_for" do
    it "returns the handler for a registered tool" do
      handler = ->(_args) { "result" }
      registry.register("test", callable: handler)
      expect(registry.handler_for("test")).to eq(handler)
    end

    it "returns nil for an unknown tool" do
      expect(registry.handler_for("unknown")).to be_nil
    end
  end

  describe "#definition_for" do
    it "returns nil for unknown tools" do
      expect(registry.definition_for("nope")).to be_nil
    end
  end

  describe "#definitions" do
    it "returns all definitions" do
      registry.register("a")
      registry.register("b")
      names = registry.definitions.map(&:name)
      expect(names).to contain_exactly("a", "b")
    end
  end

  describe "#invoke" do
    it "invokes the handler and returns a string" do
      registry.register("greet") { |args| "Hello, #{args["name"]}!" }
      result = registry.invoke("greet", {"name" => "World"})
      expect(result).to eq("Hello, World!")
    end

    it "returns non-string results as-is" do
      registry.register("number") { |_args| 42 }
      expect(registry.invoke("number", {})).to eq(42)
    end

    it "raises ToolNotFoundError for unknown tools" do
      expect {
        registry.invoke("unknown", {})
      }.to raise_error(PromptBuilder::ToolNotFoundError, /unknown/)
    end
  end
end
