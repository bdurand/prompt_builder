# frozen_string_literal: true

require "json"
require "zlib"

# Helpers for the streamed response fixtures in spec/fixtures/streams. Each
# format directory pairs a streamed body (<name>.sse, or <name>.events.json
# for Converse, which is encoded into AWS event-stream frames) with the body
# the non-streaming endpoint returns for the same response (<name>.json).
module StreamFixtures
  DIR = File.expand_path("../fixtures/streams", __dir__)

  module_function

  def names(format)
    Dir.glob(File.join(DIR, format.to_s, "*.json"))
      .reject { |path| path.end_with?(".events.json") }
      .map { |path| File.basename(path, ".json") }
      .sort
  end

  def expected(format, name)
    JSON.parse(File.read(File.join(DIR, format.to_s, "#{name}.json")))
  end

  def body(format, name)
    if format.to_s == "converse"
      events = JSON.parse(File.read(File.join(DIR, "converse", "#{name}.events.json")))
      events.map { |event| converse_event(event["event"], event["payload"]) }.join
    else
      File.binread(File.join(DIR, format.to_s, "#{name}.sse"))
    end
  end

  # Split a body into chunks of random sizes between 1 and max_size bytes.
  def random_chunks(body, random, max_size: 64)
    body = body.b
    chunks = []
    pos = 0
    while pos < body.bytesize
      size = random.rand(1..max_size)
      chunks << body.byteslice(pos, size)
      pos += size
    end
    chunks
  end

  def byte_chunks(body)
    body.b.each_char.to_a
  end

  # Encode a Converse stream event as an AWS event-stream message.
  def converse_event(type, payload)
    event_stream_message(
      {":event-type" => type, ":content-type" => "application/json", ":message-type" => "event"},
      JSON.generate(payload)
    )
  end

  # Encode an AWS event-stream message with string headers.
  def event_stream_message(headers, payload)
    header_bytes = headers.map do |name, value|
      [name.bytesize].pack("C") + name.b + [7, value.bytesize].pack("Cn") + value.b
    end.join.b
    raw_message(header_bytes, payload.b)
  end

  # Encode an AWS event-stream message from pre-encoded header bytes.
  def raw_message(header_bytes, payload)
    total_length = 12 + header_bytes.bytesize + payload.bytesize + 4
    prelude = [total_length, header_bytes.bytesize].pack("NN")
    prelude += [Zlib.crc32(prelude)].pack("N")
    message = prelude + header_bytes + payload
    message + [Zlib.crc32(message)].pack("N")
  end
end
