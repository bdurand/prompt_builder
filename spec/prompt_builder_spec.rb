# frozen_string_literal: true

require "spec_helper"

RSpec.describe PromptBuilder do
  describe "VERSION" do
    it "has a version number" do
      expect(PromptBuilder::VERSION).to eq(File.read(File.join(__dir__, "../VERSION")).strip)
    end
  end
end
