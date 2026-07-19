# Changelog

All notable changes to `dart_openapi_generator` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-07-19

### Added

- The barrel file is now named after `output_dir`'s last path segment instead of a hardcoded
  `generated.dart` — e.g. `output_dir: "lib/services/network/petstore_client"` produces
  `petstore_client.dart`. Keeps multiple generated clients in the same app collision-free.

### Changed

- Repository flattened: `packages/dart_openapi_generator/` no longer exists — the package now
  lives at the repo root (`lib/`, `test/`, `build.yaml`, `pubspec.yaml`). The repo root is both
  the published package and the pub workspace root, with `example/` as its only member.

### Fixed

- **Single-pass `build_runner build`.** The builder used to write generated files via raw
  `dart:io`, invisible to build_runner's asset graph — a downstream builder (e.g. a consumer's
  own `source_gen`-based builder importing a generated type) could never resolve them on the
  first build, only on a second, identical run. The builder factory now computes the spec's
  exact output file list *synchronously*, before build_runner freezes its asset graph, and
  `build()` writes via `buildStep.writeAsString` against those declared paths — so generated
  files are tracked like any other asset and resolve correctly in a single pass.

### Changed (breaking)

- **`dart_openapi_generator_annotations` is removed.** There is no more `@OpenApiGenerator`
  Dart annotation — configuration (`input_spec`, `output_dir`, `client_name`,
  `date_time_converter`, `debug_logging`) now lives in the `options:` block of your project's
  `build.yaml`. This is a direct consequence of the single-pass fix: config must be readable
  synchronously in the builder factory, before any Dart element resolution is possible.
- **`RemoteSpec` (HTTPS spec URLs) is removed.** Only local spec files are supported — the
  builder factory reads the spec synchronously, and there is no synchronous HTTP client in Dart.
- **The bespoke spec-unchanged cache (`CacheManager`, `skipIfSpecIsUnchanged`, `cachePath`) is
  removed.** build_runner's own incremental build engine (asset digests) now does this job for
  free, correctly, once output is tracked in its asset graph — the manual MD5/manifest cache
  only existed to work around the old dart:io write.
- **Manual `cleanOutput`/manifest-based deletion is removed.** Stale-output cleanup is handled
  by build_runner's own tracked-asset lifecycle and `--delete-conflicting-outputs`.
- `dart_openapi_generator` no longer depends on `analyzer`, `source_gen`, `http`, or `crypto` —
  none of those are needed once annotation discovery and the HTTP-based `RemoteSpec` loader are
  gone. This removes the package's only major-version-churn-prone dependency (`analyzer`).

## [0.1.1] - 2026-06-09

### Fixed

- `hashCode` generation: use `Object.hashAll` when a model has more than 20 fields — `Object.hash` accepts at most 20 positional arguments
- `_isGeneratedType`: anonymous inline schemas (`name == null`) no longer treated as generated types, preventing spurious import references in generated code
- Enum path parameters: serialize via `.toJson().toString()` before `Uri.encodeComponent` to emit the correct wire value
- Parser: empty `schema: {}` in request body or response content now yields `null` instead of a broken anonymous schema, so the generator correctly emits `Future<void>`

## [0.1.0] - 2026-05-05

### Added

- Initial release — package scaffold (full generator implementation added in v0.1.0 final).
