# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.1.1

### Changed

- Responses will now raise an `UnsupportedFormatError` if the response shape is missing key elements.
- Removed the default `max_tokens` value of 4096 from the request serializer. If `max_output_tokens` is not set on the session, the request will simply omit the `max_tokens` parameter, allowing the API to apply its own defaults.

## 0.1.0

### Added

- Initial release.
