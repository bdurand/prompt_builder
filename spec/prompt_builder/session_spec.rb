# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Session do
  before { PromptBuilder.reset_tool_registry! }

  let(:session) do
    described_class.new(
      model: "gpt-5.2",
      instructions: "You are helpful.",
      temperature: 0.7,
      max_output_tokens: 1024
    )
  end

  describe "#user" do
    it "adds a user message" do
      session.user("Hello")
      expect(session.items.length).to eq(1)
      expect(session.items[0]).to be_a(PromptBuilder::Items::Message)
      expect(session.items[0].role).to eq("user")
      expect(session.items[0].content[0].text).to eq("Hello")
    end
  end

  describe "#assistant" do
    it "adds an assistant message" do
      session.assistant("Hi there!")
      expect(session.items[0].role).to eq("assistant")
    end
  end

  describe "#system" do
    it "adds a system message" do
      session.system("Be concise.")
      expect(session.items[0].role).to eq("system")
    end
  end

  describe "#developer" do
    it "adds a developer message" do
      session.developer("Debug info")
      expect(session.items[0].role).to eq("developer")
    end
  end

  describe "#add_item" do
    it "appends a raw item" do
      item = PromptBuilder::Items::FunctionCallOutput.new(call_id: "c1", output: "done")
      session.add_item(item)
      expect(session.items).to include(item)
    end
  end

  describe "#to_h" do
    it "serializes as an Open Responses request payload" do
      session.user("Hello")
      h = session.to_h
      expect(h["model"]).to eq("gpt-5.2")
      expect(h["instructions"]).to eq("You are helpful.")
      expect(h["temperature"]).to eq(0.7)
      expect(h["max_output_tokens"]).to eq(1024)
      expect(h["input"].length).to eq(1)
      expect(h["input"][0]["type"]).to eq("message")
    end

    it "omits nil values" do
      s = described_class.new
      expect(s.to_h).to eq({})
    end

    it "includes tools when registered" do
      session.register_tool("test", description: "A test tool")
      h = session.to_h
      expect(h["tools"].length).to eq(1)
      expect(h["tools"][0]["name"]).to eq("test")
    end

    it "includes all set options" do
      s = described_class.new(
        model: "test",
        tool_choice: "auto",
        metadata: {"key" => "val"},
        top_p: 0.9,
        presence_penalty: 0.5,
        frequency_penalty: 0.3,
        parallel_tool_calls: true,
        stream: true,
        stream_options: {"include_usage" => true},
        background: false,
        max_tool_calls: 5,
        reasoning: {"effort" => "high"},
        safety_identifier: "safe_1",
        prompt_cache_key: "cache_1",
        prompt_cache_retention: "24h",
        truncation: "auto",
        store: true,
        service_tier: "default",
        top_logprobs: 5
      )
      h = s.to_h
      expect(h["tool_choice"]).to eq("auto")
      expect(h["metadata"]).to eq({"key" => "val"})
      expect(h["top_p"]).to eq(0.9)
      expect(h["presence_penalty"]).to eq(0.5)
      expect(h["frequency_penalty"]).to eq(0.3)
      expect(h["parallel_tool_calls"]).to be true
      expect(h["stream"]).to be true
      expect(h["stream_options"]).to eq({"include_usage" => true})
      expect(h["background"]).to be false
      expect(h["max_tool_calls"]).to eq(5)
      expect(h["reasoning"]).to eq({"effort" => "high"})
      expect(h["safety_identifier"]).to eq("safe_1")
      expect(h["prompt_cache_key"]).to eq("cache_1")
      expect(h["prompt_cache_retention"]).to eq("24h")
      expect(h["truncation"]).to eq("auto")
      expect(h["store"]).to be true
      expect(h["service_tier"]).to eq("default")
      expect(h["top_logprobs"]).to eq(5)
    end
  end

  describe "#add_response (local state mode)" do
    it "appends output items to the conversation" do
      session.user("Hello")
      response = PromptBuilder::Response.from_h({
        "id" => "resp_1",
        "status" => "completed",
        "output" => [
          {
            "type" => "message",
            "role" => "assistant",
            "content" => [{"type" => "output_text", "text" => "Hi!"}]
          }
        ]
      })
      session.add_response(response)
      expect(session.items.length).to eq(2)
      expect(session.items[1]).to be_a(PromptBuilder::Items::Message)
      expect(session.items[1].role).to eq("assistant")
    end
  end

  describe "#add_response (server state mode)" do
    it "updates previous_response_id" do
      s = described_class.new(previous_response_id: "resp_0")
      response = PromptBuilder::Response.new(id: "resp_1", status: "completed")
      s.add_response(response)
      expect(s.previous_response_id).to eq("resp_1")
    end

    it "appends output items to items for full local history" do
      s = described_class.new(previous_response_id: "resp_0")
      s.user("Hello")
      response = PromptBuilder::Response.from_h({
        "id" => "resp_1",
        "status" => "completed",
        "output" => [
          {
            "type" => "message",
            "role" => "assistant",
            "content" => [{"type" => "output_text", "text" => "Hi!"}]
          }
        ]
      })
      s.add_response(response)
      expect(s.items.length).to eq(2)
      expect(s.items[1]).to be_a(PromptBuilder::Items::Message)
      expect(s.items[1].role).to eq("assistant")
    end
  end

  describe "previous_response_id mode serialization" do
    it "to_h always includes full history" do
      s = described_class.new(previous_response_id: "resp_0")
      s.user("First")

      response = PromptBuilder::Response.new(id: "resp_1", status: "completed")
      s.add_response(response)

      s.user("Second")
      h = s.to_h
      expect(h["previous_response_id"]).to eq("resp_1")
      expect(h["input"].length).to eq(2)
    end

    it "OpenResponses serializer sends only new items since last response" do
      s = described_class.new(previous_response_id: "resp_0")
      s.user("First")

      response = PromptBuilder::Response.new(id: "resp_1", status: "completed")
      s.add_response(response)

      s.user("Second")
      h = s.request_payload(:open_responses)
      expect(h["previous_response_id"]).to eq("resp_1")
      expect(h["input"].length).to eq(1)
      expect(h["input"][0]["role"]).to eq("user")
    end
  end

  describe "#register_tool" do
    it "registers a tool on the session" do
      session.register_tool("greet", description: "Say hello")
      defn = session.tool_definitions.find { |d| d.name == "greet" }
      expect(defn).not_to be_nil
      expect(defn.description).to eq("Say hello")
    end
  end

  describe "#register_tools" do
    it "registers all tools from a ToolRegistry" do
      registry = PromptBuilder::ToolRegistry.new
      registry.register("tool_a", description: "Tool A") { |_| "a" }
      registry.register("tool_b", description: "Tool B") { |_| "b" }

      session.register_tools(registry)
      names = session.tool_definitions.map(&:name)
      expect(names).to contain_exactly("tool_a", "tool_b")
    end
  end

  describe "#clone_config" do
    it "creates a new session with same options but no items" do
      session.user("Hello")
      session.register_tool("test")

      cloned = session.clone_config
      expect(cloned.model).to eq("gpt-5.2")
      expect(cloned.temperature).to eq(0.7)
      expect(cloned.items).to be_empty
      expect(cloned.tool_definitions.find { |d| d.name == "test" }).not_to be_nil
    end

    it "produces an independent session" do
      cloned = session.clone_config
      cloned.user("New message")
      expect(session.items).to be_empty
    end
  end

  describe "#local_state?" do
    it "returns true when no previous_response_id" do
      expect(session).to be_local_state
    end

    it "returns false when previous_response_id is set" do
      s = described_class.new(previous_response_id: "resp_1")
      expect(s).not_to be_local_state
    end
  end

  describe "#export" do
    it "delegates to the serializer" do
      session.user("Hello")
      h = session.request_payload(PromptBuilder::Serializers::ChatCompletion)
      expect(h).to have_key("messages")
    end

    it "accepts a symbol shorthand for the serializer" do
      session.user("Hello")
      h = session.request_payload(:chat_completion)
      expect(h).to have_key("messages")
    end

    it "raises ArgumentError for an unknown symbol" do
      expect { session.request_payload(:unknown) }.to raise_error(ArgumentError, /Unknown serializer/)
    end
  end

  describe "full conversation flow" do
    it "supports create -> user -> serialize -> parse response -> add response -> serialize" do
      session.register_tool(
        "get_weather",
        description: "Get weather",
        parameters: {"type" => "object", "properties" => {"city" => {"type" => "string"}}}
      )

      session.user("What's the weather in London?")
      payload = session.to_h

      expect(payload["model"]).to eq("gpt-5.2")
      expect(payload["input"].length).to eq(1)
      expect(payload["tools"].length).to eq(1)

      # Simulate API response with tool call
      session.add_response(PromptBuilder::Response.new(id: "resp_1", status: "completed", output: [
        PromptBuilder::Items::FunctionCall.new(name: "get_weather", call_id: "call_abc", arguments: '{"city":"London"}')
      ]))
      expect(session.items.length).to eq(2)

      # Add tool output manually and prepare next API call
      session.add_item(PromptBuilder::Items::FunctionCallOutput.new(call_id: "call_abc", output: "72F sunny in London"))
      payload2 = session.to_h
      expect(payload2["input"].length).to eq(3) # user + function_call + function_call_output
    end
  end

  describe ".from_h" do
    it "restores config fields" do
      h = {
        "model" => "gpt-5.2",
        "instructions" => "Be helpful.",
        "temperature" => 0.8,
        "max_output_tokens" => 512,
        "tool_choice" => "auto",
        "top_p" => 0.9,
        "truncation" => "auto",
        "store" => true,
        "service_tier" => "default",
        "top_logprobs" => 3
      }
      s = described_class.from_h(h)
      expect(s.model).to eq("gpt-5.2")
      expect(s.instructions).to eq("Be helpful.")
      expect(s.temperature).to eq(0.8)
      expect(s.max_output_tokens).to eq(512)
      expect(s.tool_choice).to eq("auto")
      expect(s.top_p).to eq(0.9)
      expect(s.truncation).to eq("auto")
      expect(s.store).to be true
      expect(s.service_tier).to eq("default")
      expect(s.top_logprobs).to eq(3)
    end

    it "restores conversation items" do
      h = {
        "model" => "gpt-5.2",
        "input" => [
          {"type" => "message", "role" => "user", "content" => [{"type" => "input_text", "text" => "Hello"}]},
          {"type" => "message", "role" => "assistant", "content" => [{"type" => "output_text", "text" => "Hi!"}]}
        ]
      }
      s = described_class.from_h(h)
      expect(s.items.length).to eq(2)
      expect(s.items[0].role).to eq("user")
      expect(s.items[1].role).to eq("assistant")
    end

    it "restores tool definitions" do
      h = {
        "tools" => [
          {"type" => "function", "name" => "get_weather", "description" => "Get weather", "parameters" => {"type" => "object"}}
        ]
      }
      s = described_class.from_h(h)
      defn = s.tool_definitions.find { |d| d.name == "get_weather" }
      expect(defn).not_to be_nil
      expect(defn.name).to eq("get_weather")
      expect(defn.description).to eq("Get weather")
    end

    it "handles missing input and tools gracefully" do
      s = described_class.from_h({"model" => "gpt-5.2"})
      expect(s.items).to be_empty
      expect(s.tool_definitions).to be_empty
    end

    it "round-trips a session through to_h and from_h" do
      session.user("Hello")
      session.assistant("Hi there!")
      h = session.to_h
      restored = described_class.from_h(h)
      expect(restored.model).to eq(session.model)
      expect(restored.temperature).to eq(session.temperature)
      expect(restored.items.length).to eq(session.items.length)
      expect(restored.to_h).to eq(h)
    end

    it "sets previous_response_id for server state mode" do
      h = {"previous_response_id" => "resp_abc"}
      s = described_class.from_h(h)
      expect(s.previous_response_id).to eq("resp_abc")
      expect(s).not_to be_local_state
    end
  end

  describe "string input shorthand" do
    it "auto-creates a user message from a string" do
      s = described_class.new(input: "Hello!")
      expect(s.items.length).to eq(1)
      expect(s.items[0].role).to eq("user")
      expect(s.items[0].content[0].text).to eq("Hello!")
    end

    it "serializes correctly when input string is provided" do
      s = described_class.new(model: "gpt-5.2", input: "Hi")
      h = s.to_h
      expect(h["input"].length).to eq(1)
      expect(h["input"][0]["role"]).to eq("user")
      expect(h["input"][0]["content"][0]["text"]).to eq("Hi")
    end

    it "does nothing when input is nil" do
      s = described_class.new
      expect(s.items).to be_empty
    end
  end
end
