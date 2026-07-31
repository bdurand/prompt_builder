# frozen_string_literal: true

require "bundler/setup"

# SimpleCov must be started before requiring the lib
begin
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
  end
rescue LoadError
  # SimpleCov is not available
end

Bundler.require(:default, :test)

require_relative "../lib/prompt_builder"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end
