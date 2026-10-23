# frozen_string_literal: true

require "spec_helper"
require_relative "../support/stream_fixtures"

# Collapsing a streamed response must produce the same Response as parsing the
# body the non-streaming endpoint returns for the same response, however the
# stream is split into chunks.
RSpec.describe "Streamed responses" do
  # Formats whose collapsed stream reproduces the non-streamed body exactly.
  # Chat Completions omits fields the non-streaming endpoint fills with
  # defaults (e.g. "annotations": [] and "refusal": null).
  exact_formats = %i[messages open_responses gemini converse]

  %i[messages chat_completion open_responses gemini converse].each do |format|
    describe format.to_s do
      serializer = PromptBuilder::Serializers.resolve(format)

      it "has fixtures" do
        expect(StreamFixtures.names(format)).not_to be_empty
      end

      StreamFixtures.names(format).each do |name|
        describe name do
          let(:body) { StreamFixtures.body(format, name) }
          let(:expected) { StreamFixtures.expected(format, name) }
          let(:expected_response) { PromptBuilder::Response.parse(expected, format).to_h }

          it "parses to the same Response as the non-streamed body" do
            response = PromptBuilder::Response.parse_stream(body, format)
            expect(response.to_h).to eq(expected_response)
          end

          if exact_formats.include?(format)
            it "collapses to the non-streamed body" do
              expect(serializer.collapse_stream(body)).to eq(expected)
            end
          end

          it "gives the same result when fed byte by byte" do
            whole = serializer.collapse_stream(body)
            accumulator = serializer.stream_accumulator
            StreamFixtures.byte_chunks(body).each { |byte| accumulator << byte }
            expect(accumulator.result).to eq(whole)
          end

          it "gives the same result when fed in random chunk sizes" do
            whole = serializer.collapse_stream(body)
            random = Random.new(RSpec.configuration.seed)
            5.times do
              chunks = StreamFixtures.random_chunks(body, random, max_size: [1, body.bytesize / 3].max)
              expect(serializer.collapse_stream(chunks)).to eq(whole)
            end
          end

          unless format == :converse
            it "gives the same result with LF, CRLF, or CR line endings" do
              whole = serializer.collapse_stream(body)
              lf = body.gsub("\r\n", "\n")
              expect(serializer.collapse_stream(lf)).to eq(whole)
              expect(serializer.collapse_stream(lf.gsub("\n", "\r\n"))).to eq(whole)
              expect(serializer.collapse_stream(lf.tr("\n", "\r"))).to eq(whole)
            end

            it "gives the same result without the trailing blank line" do
              expect(serializer.collapse_stream(body.rstrip)).to eq(serializer.collapse_stream(body))
            end
          end
        end
      end

      it "raises IncompleteStreamError when the stream is truncated" do
        body = StreamFixtures.body(format, "text")
        truncated = (format == :converse) ? body.byteslice(0, body.bytesize / 2) : body.lines[0, 4].join
        expect { serializer.collapse_stream(truncated) }.to raise_error(PromptBuilder::IncompleteStreamError)
      end

      it "raises IncompleteStreamError when the body is empty" do
        expect { serializer.collapse_stream("") }.to raise_error(PromptBuilder::IncompleteStreamError)
      end

      it "passes through a JSON body that is not a stream so error envelopes raise when parsed" do
        error_body = case format
        when :messages then {"type" => "error", "error" => {"type" => "authentication_error", "message" => "invalid x-api-key"}}
        when :converse then {"message" => "The security token included in the request is invalid."}
        else {"error" => {"code" => 401, "type" => "invalid_request_error", "status" => "UNAUTHENTICATED", "message" => "invalid key"}}
        end
        body = "\n#{JSON.generate(error_body)}\n"

        expect(serializer.collapse_stream(body)).to eq(error_body)
        expect(serializer.collapse_stream(StreamFixtures.byte_chunks(body))).to eq(error_body)
        expect { PromptBuilder::Response.parse_stream(body, format) }
          .to raise_error(PromptBuilder::ErrorResponseError, /the API returned an error/)
      end
    end
  end
end
