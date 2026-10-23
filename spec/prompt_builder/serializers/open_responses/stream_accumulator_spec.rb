# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Serializers::OpenResponses::StreamAccumulator do
  def sse(*events, event_names: true)
    events.map do |data|
      prefix = event_names ? "event: #{data["type"]}\n" : ""
      "#{prefix}data: #{JSON.generate(data)}\n\n"
    end.join
  end

  def collapse(body)
    PromptBuilder::Serializers::OpenResponses.collapse_stream(body)
  end

  let(:response) do
    {"id" => "resp_1", "object" => "response", "status" => "completed", "model" => "gpt-4.1",
     "output" => [{"type" => "message", "id" => "msg_1", "role" => "assistant", "status" => "completed", "content" => [{"type" => "output_text", "text" => "Hi", "annotations" => []}]}]}
  end

  it "is the Open Responses serializer's stream accumulator" do
    expect(PromptBuilder::Serializers::OpenResponses.stream_accumulator).to be_a(described_class)
  end

  it "returns the response from the terminal event, ignoring other events" do
    body = sse(
      {"type" => "response.created", "response" => response.merge("status" => "in_progress", "output" => [])},
      {"type" => "response.output_text.delta", "delta" => "Hi"},
      {"type" => "response.future_event", "value" => 1},
      {"type" => "response.completed", "response" => response}
    )
    expect(collapse(body)).to eq(response)
  end

  it "reads the event type from the data when the SSE events have no names" do
    body = sse({"type" => "response.completed", "response" => response}, event_names: false)
    expect(collapse(body)).to eq(response)
  end

  it "returns a failed response so it parses into a failed Response" do
    failed = response.merge("status" => "failed", "output" => [], "error" => {"code" => "server_error", "message" => "boom"})
    parsed = PromptBuilder::Response.parse_stream(sse({"type" => "response.failed", "response" => failed}), :open_responses)
    expect(parsed).to be_failed
    expect(parsed.error).to eq("code" => "server_error", "message" => "boom")
  end

  it "raises ErrorResponseError for an error event with top-level fields" do
    body = sse({"type" => "error", "code" => "ERR_SOMETHING", "message" => "Something went wrong", "param" => nil, "sequence_number" => 1})
    expect { collapse(body) }.to raise_error(PromptBuilder::ErrorResponseError, "the API returned an error: ERR_SOMETHING: Something went wrong")
  end

  it "raises ErrorResponseError for an error event with a nested error object" do
    body = sse({"type" => "error", "error" => {"type" => "invalid_request_error", "code" => nil, "message" => "Bad input"}})
    expect { collapse(body) }.to raise_error(PromptBuilder::ErrorResponseError, "the API returned an error: invalid_request_error: Bad input")
  end

  it "raises IncompleteStreamError without a terminal event" do
    body = sse({"type" => "response.created", "response" => response.merge("status" => "in_progress")})
    expect { collapse(body) }.to raise_error(PromptBuilder::IncompleteStreamError, /response\.completed/)
  end
end
