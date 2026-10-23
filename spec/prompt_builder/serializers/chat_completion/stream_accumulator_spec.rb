# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Serializers::ChatCompletion::StreamAccumulator do
  def sse(*chunks)
    chunks.map { |chunk| "data: #{chunk.is_a?(String) ? chunk : JSON.generate(chunk)}\n\n" }.join
  end

  def chunk(choices, **fields)
    {"id" => "chatcmpl-1", "object" => "chat.completion.chunk", "created" => 1, "model" => "gpt-4o", "choices" => choices}.merge(fields.transform_keys(&:to_s))
  end

  def collapse(body)
    PromptBuilder::Serializers::ChatCompletion.collapse_stream(body)
  end

  it "is the Chat Completions serializer's stream accumulator" do
    expect(PromptBuilder::Serializers::ChatCompletion.stream_accumulator).to be_a(described_class)
  end

  it "rebuilds a chat.completion object with a message in place of the delta" do
    result = collapse(sse(
      chunk([{"index" => 0, "delta" => {"role" => "assistant", "content" => "Hel"}, "finish_reason" => nil}]),
      chunk([{"index" => 0, "delta" => {"content" => "lo"}, "finish_reason" => "stop"}]),
      "[DONE]"
    ))
    expect(result).to eq(
      "id" => "chatcmpl-1", "object" => "chat.completion", "created" => 1, "model" => "gpt-4o",
      "choices" => [{"index" => 0, "message" => {"role" => "assistant", "content" => "Hello"}, "logprobs" => nil, "finish_reason" => "stop"}]
    )
  end

  it "merges multiple choices by index" do
    result = collapse(sse(
      chunk([{"index" => 1, "delta" => {"content" => "B"}}, {"index" => 0, "delta" => {"content" => "A"}}]),
      chunk([{"index" => 0, "delta" => {"content" => "a"}, "finish_reason" => "stop"}, {"index" => 1, "delta" => {"content" => "b"}, "finish_reason" => "length"}]),
      "[DONE]"
    ))
    expect(result["choices"].map { |c| [c["index"], c["message"]["content"], c["finish_reason"]] })
      .to eq([[0, "Aa", "stop"], [1, "Bb", "length"]])
  end

  it "concatenates unknown string delta fields such as reasoning_content" do
    result = collapse(sse(
      chunk([{"index" => 0, "delta" => {"reasoning_content" => "Think"}}]),
      chunk([{"index" => 0, "delta" => {"reasoning_content" => "ing", "content" => "Done"}, "finish_reason" => "stop"}]),
      "[DONE]"
    ))
    expect(result["choices"][0]["message"]).to include("reasoning_content" => "Thinking", "content" => "Done")
  end

  it "defaults the tool call type to function when no fragment carries it" do
    result = collapse(sse(
      chunk([{"index" => 0, "delta" => {"tool_calls" => [{"index" => 0, "id" => "call_1", "function" => {"name" => "f", "arguments" => "{}"}}]}, "finish_reason" => "tool_calls"}]),
      "[DONE]"
    ))
    expect(result["choices"][0]["message"]["tool_calls"])
      .to eq([{"type" => "function", "id" => "call_1", "function" => {"name" => "f", "arguments" => "{}"}}])
  end

  it "concatenates annotations" do
    citation = {"type" => "url_citation", "url_citation" => {"url" => "https://example.com", "start_index" => 0, "end_index" => 2}}
    result = collapse(sse(
      chunk([{"index" => 0, "delta" => {"content" => "Hi", "annotations" => [citation]}, "finish_reason" => "stop"}]),
      "[DONE]"
    ))
    expect(result["choices"][0]["message"]["annotations"]).to eq([citation])
  end

  it "omits usage when the stream has no usage chunk" do
    result = collapse(sse(chunk([{"index" => 0, "delta" => {"content" => "Hi"}, "finish_reason" => "stop"}]), "[DONE]"))
    expect(result).not_to have_key("usage")
  end

  it "ignores chunks with empty choices and no usage" do
    result = collapse(sse(
      chunk([], prompt_filter_results: [{"prompt_index" => 0}]),
      chunk([{"index" => 0, "delta" => {"content" => "Hi"}, "finish_reason" => "stop"}]),
      "[DONE]"
    ))
    expect(result["choices"].length).to eq(1)
    expect(result["prompt_filter_results"]).to eq([{"prompt_index" => 0}])
  end

  it "raises ErrorResponseError for an in-stream error" do
    body = sse(
      chunk([{"index" => 0, "delta" => {"content" => "Hi"}}]),
      {"error" => {"message" => "The server had an error", "type" => "server_error", "code" => nil}}
    )
    expect { collapse(body) }.to raise_error(PromptBuilder::ErrorResponseError, "the API returned an error: server_error: The server had an error")
  end

  it "raises ErrorResponseError for a bare string error" do
    expect { collapse(sse({"error" => "upstream failed"})) }
      .to raise_error(PromptBuilder::ErrorResponseError, "the API returned an error: upstream failed")
  end

  it "raises IncompleteStreamError without data: [DONE]" do
    body = sse(chunk([{"index" => 0, "delta" => {"content" => "Hi"}, "finish_reason" => "stop"}]))
    expect { collapse(body) }.to raise_error(PromptBuilder::IncompleteStreamError, /\[DONE\]/)
  end

  it "parses into a Response with usage from the final chunk" do
    body = sse(
      chunk([{"index" => 0, "delta" => {"role" => "assistant", "content" => "Hi"}, "finish_reason" => "stop"}]),
      chunk([], usage: {"prompt_tokens" => 3, "completion_tokens" => 1, "total_tokens" => 4}),
      "[DONE]"
    )
    response = PromptBuilder::Response.parse_stream(body, :chat_completion)
    expect(response.object).to eq("chat.completion")
    expect(response.text).to eq("Hi")
    expect(response.usage.total_tokens).to eq(4)
  end
end
