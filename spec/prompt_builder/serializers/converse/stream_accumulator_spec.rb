# frozen_string_literal: true

require "spec_helper"
require_relative "../../../support/stream_fixtures"

RSpec.describe PromptBuilder::Serializers::Converse::StreamAccumulator do
  def event(type, payload)
    StreamFixtures.converse_event(type, payload)
  end

  def collapse(body)
    PromptBuilder::Serializers::Converse.collapse_stream(body)
  end

  let(:text_events) do
    [
      event("messageStart", {"role" => "assistant", "p" => "abc"}),
      event("contentBlockDelta", {"contentBlockIndex" => 0, "delta" => {"text" => "Hi"}, "p" => "abcdef"}),
      event("contentBlockStop", {"contentBlockIndex" => 0})
    ]
  end
  let(:message_stop) { event("messageStop", {"stopReason" => "end_turn", "p" => "abcdefgh"}) }
  let(:metadata) { event("metadata", {"usage" => {"inputTokens" => 3, "outputTokens" => 1, "totalTokens" => 4}, "metrics" => {"latencyMs" => 10}, "p" => "ab"}) }

  it "is the Converse serializer's stream accumulator" do
    expect(PromptBuilder::Serializers::Converse.stream_accumulator).to be_a(described_class)
  end

  it "rebuilds the ConverseResponse shape without the padding field" do
    expect(collapse([*text_events, message_stop, metadata].join)).to eq(
      "output" => {"message" => {"role" => "assistant", "content" => [{"text" => "Hi"}]}},
      "stopReason" => "end_turn",
      "usage" => {"inputTokens" => 3, "outputTokens" => 1, "totalTokens" => 4},
      "metrics" => {"latencyMs" => 10}
    )
  end

  it "passes headers through to populate the response id" do
    response = PromptBuilder::Response.parse_stream([*text_events, message_stop, metadata].join, :converse, headers: {"X-Amzn-RequestId" => "req-123"})
    expect(response.id).to eq("req-123")
    expect(response.text).to eq("Hi")
  end

  it "does not require the metadata event" do
    result = collapse([*text_events, message_stop].join)
    expect(result).not_to have_key("usage")
    expect(result["stopReason"]).to eq("end_turn")
  end

  it "raises ErrorResponseError for an exception message" do
    exception = StreamFixtures.event_stream_message(
      {":message-type" => "exception", ":exception-type" => "throttlingException", ":content-type" => "application/json"},
      JSON.generate({"message" => "Too many requests, please wait before trying again."})
    )
    expect { collapse([*text_events, exception].join) }
      .to raise_error(PromptBuilder::ErrorResponseError, "the API returned an error: throttlingException: Too many requests, please wait before trying again.")
  end

  it "uses a non-JSON exception payload as the message" do
    exception = StreamFixtures.event_stream_message({":message-type" => "exception", ":exception-type" => "internalServerException"}, "oops")
    expect { collapse(exception) }.to raise_error(PromptBuilder::ErrorResponseError, "the API returned an error: internalServerException: oops")
  end

  it "raises ErrorResponseError for an error message" do
    error = StreamFixtures.event_stream_message({":message-type" => "error", ":error-code" => "InternalFailure", ":error-message" => "Stream failed"}, "")
    expect { collapse(error) }.to raise_error(PromptBuilder::ErrorResponseError, "the API returned an error: InternalFailure: Stream failed")
  end

  it "ignores unknown events and delta types" do
    body = [
      *text_events,
      event("futureEvent", {"value" => 1}),
      event("contentBlockDelta", {"contentBlockIndex" => 0, "delta" => {"citation" => {"title" => "doc"}}}),
      message_stop
    ].join
    expect(collapse(body)["output"]["message"]["content"]).to eq([{"text" => "Hi"}])
  end

  it "raises IncompleteStreamError without messageStop" do
    expect { collapse(text_events.join) }.to raise_error(PromptBuilder::IncompleteStreamError, /messageStop/)
  end

  it "raises IncompleteStreamError when the body ends mid-frame" do
    body = [*text_events, message_stop].join
    expect { collapse(body.byteslice(0, body.bytesize - 3)) }.to raise_error(PromptBuilder::IncompleteStreamError)
  end

  it "raises ParseError on a checksum mismatch" do
    body = [*text_events, message_stop].join
    body.setbyte(body.bytesize - 6, body.getbyte(body.bytesize - 6) ^ 0x01)
    expect { collapse(body) }.to raise_error(PromptBuilder::ParseError, /checksum mismatch/)
  end

  it "parses a tool use input that is never stopped" do
    body = [
      event("contentBlockStart", {"contentBlockIndex" => 0, "start" => {"toolUse" => {"toolUseId" => "t1", "name" => "f"}}}),
      event("contentBlockDelta", {"contentBlockIndex" => 0, "delta" => {"toolUse" => {"input" => "{\"a\":1}"}}}),
      event("messageStop", {"stopReason" => "tool_use"})
    ].join
    expect(collapse(body)["output"]["message"]["content"]).to eq([{"toolUse" => {"toolUseId" => "t1", "name" => "f", "input" => {"a" => 1}}}])
  end

  it "raises ParseError when tool input fragments are not valid JSON" do
    body = [
      event("contentBlockStart", {"contentBlockIndex" => 0, "start" => {"toolUse" => {"toolUseId" => "t1", "name" => "f"}}}),
      event("contentBlockDelta", {"contentBlockIndex" => 0, "delta" => {"toolUse" => {"input" => "{\"a\":"}}}),
      event("contentBlockStop", {"contentBlockIndex" => 0})
    ].join
    expect { collapse(body) }.to raise_error(PromptBuilder::ParseError)
  end
end
