# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Serializers::Messages::StreamAccumulator do
  def sse(*events)
    events.map { |data| "event: #{data["type"]}\ndata: #{JSON.generate(data)}\n\n" }.join
  end

  let(:message_start) do
    {"type" => "message_start", "message" => {"id" => "msg_1", "type" => "message", "role" => "assistant", "content" => [], "model" => "claude-sonnet-4-5", "stop_reason" => nil, "usage" => {"input_tokens" => 10, "output_tokens" => 1}}}
  end
  let(:message_delta) { {"type" => "message_delta", "delta" => {"stop_reason" => "end_turn", "stop_sequence" => nil}, "usage" => {"output_tokens" => 5}} }
  let(:message_stop) { {"type" => "message_stop"} }

  def text_block(index, text)
    [
      {"type" => "content_block_start", "index" => index, "content_block" => {"type" => "text", "text" => ""}},
      {"type" => "content_block_delta", "index" => index, "delta" => {"type" => "text_delta", "text" => text}},
      {"type" => "content_block_stop", "index" => index}
    ]
  end

  it "is the Messages serializer's stream accumulator" do
    expect(PromptBuilder::Serializers::Messages.stream_accumulator).to be_a(described_class)
  end

  it "raises ErrorResponseError for an in-stream error event" do
    body = sse(message_start, *text_block(0, "Hi"), {"type" => "error", "error" => {"type" => "overloaded_error", "message" => "Overloaded"}})
    expect { PromptBuilder::Serializers::Messages.collapse_stream(body) }
      .to raise_error(PromptBuilder::ErrorResponseError, "the API returned an error: overloaded_error: Overloaded")
  end

  it "raises the error as soon as the error event is fed" do
    accumulator = described_class.new
    accumulator << sse(message_start)
    expect { accumulator << sse({"type" => "error", "error" => {"type" => "api_error", "message" => "boom"}}) }
      .to raise_error(PromptBuilder::ErrorResponseError, /api_error: boom/)
    expect { accumulator.result }.to raise_error(PromptBuilder::ErrorResponseError, /api_error: boom/)
  end

  it "ignores ping and unknown events and delta types" do
    body = sse(
      message_start,
      {"type" => "ping"},
      {"type" => "content_block_start", "index" => 0, "content_block" => {"type" => "text", "text" => ""}},
      {"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "future_delta", "value" => 1}},
      {"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "text_delta", "text" => "Hi"}},
      {"type" => "content_block_stop", "index" => 0},
      {"type" => "future_event", "payload" => {}},
      message_delta,
      message_stop
    )
    result = PromptBuilder::Serializers::Messages.collapse_stream(body)
    expect(result["content"]).to eq([{"type" => "text", "text" => "Hi"}])
  end

  it "raises IncompleteStreamError without message_stop" do
    body = sse(message_start, *text_block(0, "Hi"), message_delta)
    expect { PromptBuilder::Serializers::Messages.collapse_stream(body) }
      .to raise_error(PromptBuilder::IncompleteStreamError, /message_stop/)
  end

  it "raises IncompleteStreamError without message_start" do
    body = sse(*text_block(0, "Hi"), message_delta, message_stop)
    expect { PromptBuilder::Serializers::Messages.collapse_stream(body) }
      .to raise_error(PromptBuilder::IncompleteStreamError, /message_start/)
  end

  it "merges cumulative message_delta usage into the message_start usage, ignoring nulls" do
    delta = message_delta.merge("usage" => {"output_tokens" => 42, "input_tokens" => nil, "cache_read_input_tokens" => 7})
    result = PromptBuilder::Serializers::Messages.collapse_stream(sse(message_start, *text_block(0, "Hi"), delta, message_stop))
    expect(result["usage"]).to eq("input_tokens" => 10, "output_tokens" => 42, "cache_read_input_tokens" => 7)
    expect(result["stop_reason"]).to eq("end_turn")
  end

  it "parses the input of a tool use block that is never stopped" do
    body = sse(
      message_start,
      {"type" => "content_block_start", "index" => 0, "content_block" => {"type" => "tool_use", "id" => "toolu_1", "name" => "lookup", "input" => {}}},
      {"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "input_json_delta", "partial_json" => "{\"q\": 1}"}},
      message_delta,
      message_stop
    )
    result = PromptBuilder::Serializers::Messages.collapse_stream(body)
    expect(result["content"]).to eq([{"type" => "tool_use", "id" => "toolu_1", "name" => "lookup", "input" => {"q" => 1}}])
  end

  it "raises ParseError when tool input fragments are not valid JSON" do
    body = sse(
      message_start,
      {"type" => "content_block_start", "index" => 0, "content_block" => {"type" => "tool_use", "id" => "toolu_1", "name" => "lookup", "input" => {}}},
      {"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "input_json_delta", "partial_json" => "{\"q\": "}},
      {"type" => "content_block_stop", "index" => 0}
    )
    expect { PromptBuilder::Serializers::Messages.collapse_stream(body) }.to raise_error(PromptBuilder::ParseError)
  end

  it "raises ParseError when an event's data is not valid JSON" do
    expect { PromptBuilder::Serializers::Messages.collapse_stream("event: message_start\ndata: {not json\n\n") }
      .to raise_error(PromptBuilder::ParseError, /not valid JSON/)
  end

  it "orders content blocks by index" do
    body = sse(message_start, *text_block(1, "second"), *text_block(0, "first"), message_delta, message_stop)
    result = PromptBuilder::Serializers::Messages.collapse_stream(body)
    expect(result["content"].map { |block| block["text"] }).to eq(%w[first second])
  end

  it "reads the event type from the SSE event field when the data has none" do
    body = "event: message_start\ndata: #{JSON.generate(message_start.except("type"))}\n\n" \
      "#{sse(*text_block(0, "Hi"), message_delta)}event: message_stop\ndata: {}\n\n"
    result = PromptBuilder::Serializers::Messages.collapse_stream(body)
    expect(result["id"]).to eq("msg_1")
  end

  it "raises InvalidStateError when fed after result" do
    accumulator = described_class.new
    accumulator << sse(message_start, *text_block(0, "Hi"), message_delta, message_stop)
    result = accumulator.result
    expect(accumulator.result).to equal(result)
    expect { accumulator << "data: {}\n\n" }.to raise_error(PromptBuilder::InvalidStateError)
  end
end
