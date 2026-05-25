# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Changed

- Serializers now silently omit unsupported features from the serialized output
  instead of raising `UnsupportedFormatError`. Unsupported session fields, content
  types, enum values, sub-keys, `tool_choice` variants, and `Compaction`/`ItemReference`
  items are dropped from request payloads; unrecognized blocks, candidates, and choices
  are skipped when parsing responses. `UnsupportedFormatError` is still raised for
  missing required data (e.g. no `model`, no messages, a `json_schema` format without a
  schema), structural problems, genuine conflicts, unparseable function-call arguments,
  and streaming response chunks.

## 1.0.0

### Added

- Initial release.
