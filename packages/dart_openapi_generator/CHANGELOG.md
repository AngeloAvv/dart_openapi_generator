# Changelog

All notable changes to `dart_openapi_generator` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-06-09

### Fixed

- `hashCode` generation: use `Object.hashAll` when a model has more than 20 fields — `Object.hash` accepts at most 20 positional arguments
- `_isGeneratedType`: anonymous inline schemas (`name == null`) no longer treated as generated types, preventing spurious import references in generated code
- Enum path parameters: serialize via `.toJson().toString()` before `Uri.encodeComponent` to emit the correct wire value
- Parser: empty `schema: {}` in request body or response content now yields `null` instead of a broken anonymous schema, so the generator correctly emits `Future<void>`

## [0.1.0] - 2026-05-05

### Added

- Initial release — package scaffold (full generator implementation added in v0.1.0 final).
