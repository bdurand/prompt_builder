# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Serializers::Gemini::StreamAccumulator do
  def sse(*chunks)
    chunks.map { |chunk| "data: #{JSON.generate(chunk)}\r\n\r\n" }.join
  end

  def chunk(parts, finish_reason: nil, index: 0)
    candidate = {"content" => {"role" => "model", "parts" => parts}, "index" => index}
    candidate["finishReason"] = finish_reason if finish_reason
    {"candidates" => [candidate], "modelVersion" => "gemini-2.5-flash", "responseId" => "r1"}
  end

  def collapse(body)
    PromptBuilder::Serializers::Gemini.collapse_stream(body)
  end

  def parts(result, index = 0)
    result["candidates"][index]["content"]["parts"]
  end

  it "is the Gemini serializer's stream accumulator" do
    expect(PromptBuilder::Serializers::Gemini.stream_accumulator).to be_a(described_class)
  end

  it "keeps adjacent text parts separate when both carry a thought signature" do
    result = collapse(sse(
      chunk([{"text" => "a", "thoughtSignature" => "s1"}]),
      chunk([{"text" => "b", "thoughtSignature" => "s2"}], finish_reason: "STOP")
    ))
    expect(parts(result)).to eq([{"text" => "a", "thoughtSignature" => "s1"}, {"text" => "b", "thoughtSignature" => "s2"}])
  end

  it "keeps the signature when a signed part is followed by unsigned text" do
    result = collapse(sse(
      chunk([{"text" => "a", "thoughtSignature" => "s1"}]),
      chunk([{"text" => "b"}], finish_reason: "STOP")
    ))
    expect(parts(result)).to eq([{"text" => "ab", "thoughtSignature" => "s1"}])
  end

  it "does not merge text across a function call or other part types" do
    call = {"functionCall" => {"name" => "f", "args" => {}}}
    code = {"executableCode" => {"language" => "PYTHON", "code" => "1"}}
    result = collapse(sse(
      chunk([{"text" => "a"}, call]),
      chunk([{"text" => "b"}, code, {"text" => "c"}], finish_reason: "STOP")
    ))
    expect(parts(result)).to eq([{"text" => "a"}, call, {"text" => "b"}, code, {"text" => "c"}])
  end

  it "merges candidates by index" do
    result = collapse(sse(
      {"candidates" => [{"index" => 0, "content" => {"parts" => [{"text" => "A"}]}}, {"index" => 1, "content" => {"parts" => [{"text" => "B"}]}}], "modelVersion" => "m"},
      {"candidates" => [{"index" => 1, "content" => {"parts" => [{"text" => "b"}]}, "finishReason" => "STOP"}, {"index" => 0, "content" => {"parts" => [{"text" => "a"}]}, "finishReason" => "STOP"}], "modelVersion" => "m"}
    ))
    expect(result["candidates"].map { |candidate| candidate["content"]["parts"] }).to eq([[{"text" => "Aa"}], [{"text" => "Bb"}]])
  end

  it "raises IncompleteStreamError when a candidate has no finishReason" do
    expect { collapse(sse(chunk([{"text" => "a"}]))) }
      .to raise_error(PromptBuilder::IncompleteStreamError, /finishReason/)
  end

  it "raises IncompleteStreamError when only some candidates finished" do
    body = sse(
      {"candidates" => [{"index" => 0, "content" => {"parts" => [{"text" => "A"}]}, "finishReason" => "STOP"}, {"index" => 1, "content" => {"parts" => [{"text" => "B"}]}}], "modelVersion" => "m"}
    )
    expect { collapse(body) }.to raise_error(PromptBuilder::IncompleteStreamError)
  end

  it "raises ErrorResponseError for an in-stream error" do
    body = sse(chunk([{"text" => "a"}]), {"error" => {"code" => 503, "message" => "The model is overloaded.", "status" => "UNAVAILABLE"}})
    expect { collapse(body) }.to raise_error(PromptBuilder::ErrorResponseError, "the API returned an error: UNAVAILABLE: The model is overloaded.")
  end

  it "ignores unknown fields by keeping the last value" do
    result = collapse(sse(
      chunk([{"text" => "a"}]).merge("futureField" => 1),
      chunk([{"text" => "b"}], finish_reason: "STOP").merge("futureField" => 2)
    ))
    expect(result["futureField"]).to eq(2)
  end

  it "merges a JSON array body returned without alt=sse" do
    body = JSON.generate([chunk([{"text" => "a"}]), chunk([{"text" => "b"}], finish_reason: "STOP")])
    result = collapse(body)
    expect(parts(result)).to eq([{"text" => "ab"}])
    expect(result["candidates"][0]["finishReason"]).to eq("STOP")
  end

  it "raises IncompleteStreamError for a truncated JSON array body's chunks" do
    expect { collapse(JSON.generate([chunk([{"text" => "a"}])])) }.to raise_error(PromptBuilder::IncompleteStreamError)
  end

  it "parses a blocked prompt into a failed Response" do
    body = sse({"promptFeedback" => {"blockReason" => "SAFETY"}, "modelVersion" => "gemini-2.5-flash"})
    expect(PromptBuilder::Response.parse_stream(body, :gemini)).to be_failed
  end
end
