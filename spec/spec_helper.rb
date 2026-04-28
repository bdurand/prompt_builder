# frozen_string_literal: true

require "bundler/setup"

require_relative "../lib/base_gem"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end
