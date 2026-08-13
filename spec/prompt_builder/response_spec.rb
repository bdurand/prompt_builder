# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Response do
  let(:response_hash) do
    {
      "id" => "resp_123",
      "object" => "response",
      "created_at" => 1700000000,
      "completed_at" => 1700000005,
      "status" => "completed",
      "model" => "gpt-5.2",
      "output" => [
        {
          "type" => "message",
          "role" => "assistant",
          "content" => [{"type" => "output_text", "text" => "Hello!"}]
        }
      ],
      "usage" => {
        "input_tokens" => 10,
        "output_tokens" => 5,
        "total_tokens" => 15,
        "input_tokens_details" => {"cached_tokens" => 2},
        "output_tokens_details" => {"reasoning_tokens" => 3}
      }
    }
  end

  describe ".parse" do
    it "delegates to the serializer class and returns a Response" do
      response = described_class.parse(response_hash, PromptBuilder::Serializers::OpenResponses)
      expect(response).to be_a(described_class)
      expect(response.id).to eq("resp_123")
      expect(response.status).to eq("completed")
    end

    it "resolves a symbol to the correct serializer" do
      response = described_class.parse(response_hash, :open_responses)
      expect(response).to be_a(described_class)
      expect(response.id).to eq("resp_123")
    end

    it "accepts :chat_completion symbol" do
      openai_hash = {
        "id" => "chatcmpl-abc",
        "object" => "chat.completion",
        "created" => 1700000000,
        "model" => "gpt-4o",
        "choices" => [
          {
            "index" => 0,
            "message" => {"role" => "assistant", "content" => "Hello!"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => {"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }
      response = described_class.parse(openai_hash, :chat_completion)
      expect(response).to be_a(described_class)
      expect(response.text).to eq("Hello!")
    end

    it "raises ArgumentError for unknown symbol" do
      expect { described_class.parse({}, :unknown_format) }
        .to raise_error(ArgumentError, /Unknown serializer/)
    end

    it "forwards HTTP headers to the serializer" do
      converse_hash = {
        "output" => {
          "message" => {"role" => "assistant", "content" => [{"text" => "Hello!"}]}
        },
        "stopReason" => "end_turn"
      }
      response = described_class.parse(converse_hash, :converse, headers: {"x-amzn-requestid" => "req-123"})
      expect(response.id).to eq("req-123")
    end
  end

  describe ".from_h" do
    it "parses a response hash" do
      response = described_class.from_h(response_hash)
      expect(response.id).to eq("resp_123")
      expect(response.object).to eq("response")
      expect(response.created_at).to eq(1700000000)
      expect(response.completed_at).to eq(1700000005)
      expect(response.status).to eq("completed")
      expect(response.model).to eq("gpt-5.2")
      expect(response.output.length).to eq(1)
      expect(response.output[0]).to be_a(PromptBuilder::Items::Message)
      expect(response.usage.input_tokens).to eq(10)
      expect(response.usage.output_tokens).to eq(5)
      expect(response.usage.total_tokens).to eq(15)
      expect(response.usage.cached_tokens).to eq(2)
      expect(response.usage.reasoning_tokens).to eq(3)
    end

    it "handles missing optional fields" do
      response = described_class.from_h({"status" => "completed"})
      expect(response.id).to be_nil
      expect(response.output).to eq([])
      expect(response.usage).to be_nil
    end
  end

  describe "#provider_data" do
    it "is an alias for extra" do
      response = described_class.new(status: "completed", extra: {"system_fingerprint" => "fp_1"})
      expect(response.provider_data).to eq({"system_fingerprint" => "fp_1"})
      expect(response.provider_data).to eq(response.extra)
    end
  end

  describe "#completed?" do
    it "returns true when completed" do
      response = described_class.from_h({"status" => "completed"})
      expect(response).to be_completed
    end

    it "returns false when not completed" do
      response = described_class.from_h({"status" => "failed"})
      expect(response).not_to be_completed
    end
  end

  describe "#failed?" do
    it "returns true when failed" do
      response = described_class.from_h({"status" => "failed"})
      expect(response).to be_failed
    end
  end

  describe "#incomplete?" do
    it "returns true when incomplete" do
      response = described_class.from_h({"status" => "incomplete"})
      expect(response).to be_incomplete
    end
  end

  describe "#has_tool_calls?" do
    it "returns true when output contains function calls" do
      response = described_class.from_h({
        "output" => [{
          "type" => "function_call",
          "name" => "get_weather",
          "call_id" => "call_1",
          "arguments" => "{}"
        }]
      })
      expect(response).to have_tool_calls
    end

    it "returns false when no function calls" do
      response = described_class.from_h(response_hash)
      expect(response).not_to have_tool_calls
    end
  end

  describe "#tool_calls" do
    it "returns function call items" do
      response = described_class.from_h({
        "output" => [
          {
            "type" => "message",
            "role" => "assistant",
            "content" => [{"type" => "output_text", "text" => "Let me check."}]
          },
          {
            "type" => "function_call",
            "name" => "get_weather",
            "call_id" => "call_1",
            "arguments" => '{"city":"London"}'
          }
        ]
      })
      calls = response.tool_calls
      expect(calls.length).to eq(1)
      expect(calls[0].name).to eq("get_weather")
    end
  end

  describe "#text" do
    it "extracts text from the first output message" do
      response = described_class.from_h(response_hash)
      expect(response.text).to eq("Hello!")
    end

    it "returns nil when no text output" do
      response = described_class.from_h({
        "output" => [{
          "type" => "function_call",
          "name" => "test",
          "call_id" => "call_1",
          "arguments" => "{}"
        }]
      })
      expect(response.text).to be_nil
    end

    it "concatenates multiple text blocks" do
      response = described_class.from_h({
        "output" => [{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            {"type" => "output_text", "text" => "Hello "},
            {"type" => "output_text", "text" => "World!"}
          ]
        }]
      })
      expect(response.text).to eq("Hello World!")
    end
  end

  describe "#parsed_json" do
    def response_with_text(text)
      described_class.from_h({
        "output" => [{
          "type" => "message",
          "role" => "assistant",
          "content" => [{"type" => "output_text", "text" => text}]
        }]
      })
    end

    it "parses clean JSON output" do
      response = response_with_text('{"answer": 42}')
      expect(response.parsed_json).to eq({"answer" => 42})
    end

    it "parses fenced ```json output" do
      response = response_with_text("```json\n{\"answer\": 42}\n```")
      expect(response.parsed_json).to eq({"answer" => 42})
    end

    it "parses fenced output without a language tag" do
      response = response_with_text("```\n[1, 2, 3]\n```")
      expect(response.parsed_json).to eq([1, 2, 3])
    end

    it "returns nil when the response has no text" do
      response = described_class.from_h({"status" => "completed"})
      expect(response.parsed_json).to be_nil
    end

    it "returns nil when the text is not valid JSON" do
      response = response_with_text("I'm sorry, I can't do that.")
      expect(response.parsed_json).to be_nil
    end
  end

  describe "#parsed_json!" do
    def response_with_text(text)
      described_class.from_h({
        "output" => [{
          "type" => "message",
          "role" => "assistant",
          "content" => [{"type" => "output_text", "text" => text}]
        }]
      })
    end

    it "parses JSON output" do
      response = response_with_text('{"answer": 42}')
      expect(response.parsed_json!).to eq({"answer" => 42})
    end

    it "raises ParseError including the raw text when the text is not valid JSON" do
      response = response_with_text("not json at all")
      expect {
        response.parsed_json!
      }.to raise_error(PromptBuilder::ParseError, /not json at all/)
    end

    it "raises ParseError when the response has no text" do
      response = described_class.from_h({"status" => "completed"})
      expect { response.parsed_json! }.to raise_error(PromptBuilder::ParseError, /no text/)
    end
  end

  describe ".from_text" do
    it "synthesizes a completed assistant text response" do
      response = described_class.from_text("Authentication failed.")

      expect(response.status).to eq("completed")
      expect(response).to be_completed
      expect(response.text).to eq("Authentication failed.")
      expect(response.output.length).to eq(1)
      expect(response.output.first.role).to eq("assistant")
    end

    it "accepts model, usage, and other response attributes" do
      usage = PromptBuilder::Usage.new(input_tokens: 10, output_tokens: 5)
      response = described_class.from_text("Cached answer.", model: "gpt-5.2", usage: usage, id: "resp_9")

      expect(response.model).to eq("gpt-5.2")
      expect(response.usage.input_tokens).to eq(10)
      expect(response.id).to eq("resp_9")
    end

    it "accepts an explicit status" do
      response = described_class.from_text("Stopped.", status: "incomplete")
      expect(response).to be_incomplete
    end

    it "round-trips through to_h and from_h" do
      response = described_class.from_text("Hello!", model: "gpt-5.2")
      restored = described_class.from_h(response.to_h)

      expect(restored.text).to eq("Hello!")
      expect(restored.model).to eq("gpt-5.2")
      expect(restored.status).to eq("completed")
    end
  end

  describe "#to_h" do
    it "round-trips through from_h and to_h" do
      response = described_class.from_h(response_hash)
      h = response.to_h
      expect(h["id"]).to eq("resp_123")
      expect(h["status"]).to eq("completed")
      expect(h["model"]).to eq("gpt-5.2")
      expect(h["output"].length).to eq(1)
      expect(h["usage"]["input_tokens"]).to eq(10)
      expect(h["usage"]["total_tokens"]).to eq(15)
    end

    it "omits nil values" do
      response = described_class.from_h({"status" => "completed"})
      h = response.to_h
      expect(h).not_to have_key("id")
      expect(h).not_to have_key("model")
      expect(h).not_to have_key("usage")
    end
  end
end
