# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder::Content do
  describe ".data_url" do
    it "delegates to PromptBuilder.data_url" do
      url = described_class.data_url("hello world", "text/plain")
      expect(url).to eq(PromptBuilder.data_url("hello world", "text/plain"))
    end
  end
end
