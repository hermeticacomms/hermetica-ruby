# frozen_string_literal: true

require_relative "lib/hermetica/version"

Gem::Specification.new do |spec|
  spec.name = "hermeticacomms"
  spec.version = Hermetica::VERSION
  spec.authors = ["Hermetica"]
  spec.summary = "Ruby client for the Hermetica API"
  spec.description = "Standard-library Ruby client for the Hermetica API: one method per operation, idempotency keys, cursor paging."
  spec.homepage = "https://github.com/hermeticacomms/hermetica-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"
  spec.metadata = { "source_code_uri" => spec.homepage }
  spec.files = Dir["lib/**/*.rb"] + ["README.md", "LICENSE"].select { |f| File.exist?(f) }
  spec.require_paths = ["lib"]
end
