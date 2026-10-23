# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/stream_fixtures"

RSpec.describe PromptBuilder::Streaming::EventStreamDecoder do
  def decode(*chunks)
    decoder = described_class.new
    messages = []
    chunks.each { |chunk| decoder.feed(chunk) { |message| messages << message } }
    decoder.finish
    messages
  end

  let(:message) do
    StreamFixtures.event_stream_message(
      {":message-type" => "event", ":event-type" => "contentBlockDelta", ":content-type" => "application/json"},
      '{"delta":{"text":"café"}}'
    )
  end

  it "decodes headers and payload" do
    decoded = decode(message)
    expect(decoded.length).to eq(1)
    expect(decoded.first.headers).to eq(
      ":message-type" => "event", ":event-type" => "contentBlockDelta", ":content-type" => "application/json"
    )
    expect(decoded.first.payload).to eq('{"delta":{"text":"café"}}'.b)
  end

  it "decodes messages split at every byte" do
    body = message + message
    expect(decode(*body.each_char.to_a).length).to eq(2)
  end

  it "decodes a message with no headers and no payload" do
    decoded = decode(StreamFixtures.raw_message("".b, "".b))
    expect(decoded.first.to_h).to eq(headers: {}, payload: "".b)
  end

  it "decodes every header value type" do
    header = ->(name, type, value) { [name.bytesize].pack("C") + name.b + [type].pack("C") + value.b }
    header_bytes = [
      header.call("true", 0, ""),
      header.call("false", 1, ""),
      header.call("byte", 2, [-2].pack("c")),
      header.call("short", 3, [-300].pack("s>")),
      header.call("int", 4, [70_000].pack("l>")),
      header.call("long", 5, [5_000_000_000].pack("q>")),
      header.call("bytes", 6, [3].pack("n") + "\x00\x01\x02".b),
      header.call("string", 7, [5].pack("n") + "héllo".b[0, 5]),
      header.call("timestamp", 8, [1_700_000_000_123].pack("q>")),
      header.call("uuid", 9, ["0123456789abcdef0123456789abcdef"].pack("H*"))
    ].join

    headers = decode(StreamFixtures.raw_message(header_bytes, "".b)).first.headers
    expect(headers["true"]).to be(true)
    expect(headers["false"]).to be(false)
    expect(headers["byte"]).to eq(-2)
    expect(headers["short"]).to eq(-300)
    expect(headers["int"]).to eq(70_000)
    expect(headers["long"]).to eq(5_000_000_000)
    expect(headers["bytes"]).to eq("\x00\x01\x02".b)
    expect(headers["string"]).to eq("héll")
    expect(headers["timestamp"]).to eq(Time.at(1_700_000_000, 123, :millisecond).utc)
    expect(headers["uuid"]).to eq("01234567-89ab-cdef-0123-456789abcdef")
  end

  it "raises ParseError on a prelude checksum mismatch" do
    corrupt = message.dup
    corrupt.setbyte(9, corrupt.getbyte(9) ^ 0xFF)
    expect { decode(corrupt) }.to raise_error(PromptBuilder::ParseError, /prelude checksum mismatch/)
  end

  it "raises ParseError on a message checksum mismatch" do
    corrupt = message.dup
    corrupt.setbyte(20, corrupt.getbyte(20) ^ 0xFF)
    expect { decode(corrupt) }.to raise_error(PromptBuilder::ParseError, /message checksum mismatch/)
  end

  it "raises ParseError on an unknown header value type" do
    header_bytes = [4].pack("C") + "name".b + [42].pack("C")
    expect { decode(StreamFixtures.raw_message(header_bytes, "".b)) }
      .to raise_error(PromptBuilder::ParseError, /unknown event stream header value type 42/)
  end

  it "raises ParseError on truncated headers" do
    header_bytes = [4].pack("C") + "name".b + [7].pack("C") + [10].pack("n") + "abc".b
    expect { decode(StreamFixtures.raw_message(header_bytes, "".b)) }
      .to raise_error(PromptBuilder::ParseError, /headers are truncated/)
  end

  it "raises ParseError when the headers length exceeds the message length" do
    prelude = [16, 100].pack("NN")
    prelude += [Zlib.crc32(prelude)].pack("N")
    expect { decode(prelude + [0].pack("N")) }.to raise_error(PromptBuilder::ParseError, /too short/)
  end

  it "raises IncompleteStreamError when the body ends in the middle of a message" do
    expect { decode(message.byteslice(0, message.bytesize - 1)) }
      .to raise_error(PromptBuilder::IncompleteStreamError, /left over/)
  end
end
