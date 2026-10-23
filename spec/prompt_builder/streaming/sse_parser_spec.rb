# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Streaming::SSEParser do
  def parse(*chunks)
    parser = described_class.new
    events = []
    chunks.each { |chunk| parser.feed(chunk) { |event| events << event } }
    parser.finish { |event| events << event }
    events
  end

  it "parses event, data, and id fields" do
    events = parse("event: greeting\ndata: hello\nid: 7\n\n")
    expect(events.map(&:to_h)).to eq([{event: "greeting", data: "hello", id: "7"}])
  end

  it "joins multi-line data with newlines" do
    events = parse("data: line one\ndata: line two\ndata:\n\n")
    expect(events.map(&:data)).to eq(["line one\nline two\n"])
  end

  it "removes only one leading space from a field value" do
    events = parse("data:no space\n\ndata:  two spaces\n\n")
    expect(events.map(&:data)).to eq(["no space", " two spaces"])
  end

  it "ignores comment lines and unknown fields" do
    events = parse(": keep-alive\nretry: 1000\nfoo: bar\ndata: x\n\n:another comment\n\n")
    expect(events.map(&:data)).to eq(["x"])
  end

  it "does not dispatch events without data" do
    events = parse("event: ping\n\ndata: x\n\n")
    expect(events.map(&:to_h)).to eq([{event: nil, data: "x", id: nil}])
  end

  it "keeps the last event id for later events" do
    events = parse("id: 1\ndata: a\n\ndata: b\n\n")
    expect(events.map(&:id)).to eq(["1", "1"])
  end

  it "ignores an id containing a NUL character" do
    events = parse("id: a\0b\ndata: x\n\n")
    expect(events.first.id).to be_nil
  end

  it "treats a line with no colon as a field with an empty value" do
    events = parse("data\ndata: x\n\n")
    expect(events.map(&:data)).to eq(["\nx"])
  end

  it "handles CRLF and CR line endings" do
    expect(parse("data: a\r\n\r\ndata: b\r\rdata: c\n\n").map(&:data)).to eq(%w[a b c])
  end

  it "handles a CRLF split across chunks" do
    expect(parse("data: a\r", "\n\r", "\ndata: b\r", "\r").map(&:data)).to eq(%w[a b])
  end

  it "treats a trailing CR at the end of the stream as a line ending" do
    expect(parse("data: a\r").map(&:data)).to eq(["a"])
  end

  it "dispatches a final event that has no trailing blank line" do
    expect(parse("data: a\n\ndata: b").map(&:data)).to eq(%w[a b])
  end

  it "reassembles UTF-8 characters split across chunks" do
    bytes = "data: café ☕\n\n".b
    events = parse(*bytes.each_char.to_a)
    expect(events.first.data).to eq("café ☕")
    expect(events.first.data.encoding).to eq(Encoding::UTF_8)
  end

  it "skips a leading byte order mark, even when split across chunks" do
    expect(parse("\xEF".b, "\xBB".b, "\xBFdata: a\n\n").map(&:data)).to eq(["a"])
  end

  it "yields events as soon as they are complete" do
    parser = described_class.new
    events = []
    parser.feed("data: a\n\ndata: b") { |event| events << event.data }
    expect(events).to eq(["a"])
  end
end
