# Changelog

All notable changes to `dart_openapi_generator` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-08-18

### Fixed

- **`oneOf` branches that are `$ref`s to component schemas are no longer stolen from the rest of the spec.** A `oneOf` variant was assumed to be a type dedicated to that one union, so every variant was emitted *inside* the wrapper's file and skipped in the standalone-file loop. For a `$ref` branch that assumption is wrong: `#/components/schemas/Customer` is a shared component, and other schemas reference it. The result was that `models/customer.dart` was never written while every model with a `$ref: Customer` property still imported it (`uri_does_not_exist`, `undefined_class`), and that a component used by two unions — the request and the response of one endpoint, typically — was emitted twice with two different supertypes (`ambiguous_export` on the barrel). A component is now emitted exactly once and reused: the reproduction from the bug report goes from 5 analysis errors to none.
- **Anonymous `oneOf` branches no longer crash the generator.** An inline (non-`$ref`) variant was looked up in the name registry under a synthesised name that was never registered, throwing `StateError`. Those names are registered now, which also gives them the usual duplicate-name detection.
- **Top-level `typedef Name = List<Item>;` schemas now import their item type.** The alias was emitted without the import it needs.
- **Path parameters that are not strings no longer break compilation.** `Uri.encodeComponent` takes a `String`, but the generated service passed the parameter as-is for everything except enums, so `{ "type": "integer" }` on a path parameter emitted `Uri.encodeComponent(id)` and failed with `argument_type_not_assignable`. The Dart type was always correct — only the URL serialization was missing. The only workaround was to declare the parameter as a string in the spec. Non-string parameters are now converted (`id.toString()`), and generated types serialize through `toJson()` first so their wire value is used. String parameters are emitted exactly as before. An array path parameter converts as well but warns, since OpenAPI `style`/`explode` are not implemented.
- **Synthesised `oneOf` variant class names no longer collide with a real component schema.** The class generated for a non-object branch is named `<Wrapper><TypeSuffix>` (e.g. `FooString`); a spec that also declares a component with that exact name produced two classes with the same name in two files — `ambiguous_export` on the barrel, the very failure this release fixes. The synthesised name now yields and is disambiguated automatically (`FooString2`), so the user's component always keeps its name.
- **A `oneOf` branch whose `$ref` cannot be resolved to a component schema no longer crashes the build.** It used to reach the name registry unregistered and throw a raw `StateError` with an internal message. The branch is now skipped with a warning naming the unresolved target, and the rest of the union is still generated.
- **A list response whose items are a polymorphic `oneOf` no longer throws at runtime.** Each item was decoded with `Wrapper.fromJson(e as Map<String, dynamic>)`; an element matching the union's non-object branch — the only reason that branch exists — failed the cast. The cast is gone; the generated `fromJson` already accepts `Object?`.

### Changed (breaking)

- **A `oneOf` wrapper and its `$ref` branches are emitted into the same file, and the branches `implements` the wrapper instead of extending it.** Dart only allows a `sealed` type to be implemented from within its own library, and a `sealed` wrapper is what makes `switch` exhaustiveness work. Keeping both properties — reusable standalone branches *and* an exhaustive union — requires them to share a library. Two unions that share a branch are therefore emitted together. Consequences for existing code: pattern matching (`case Circle c:`) is unaffected, but a class that used to `extend` its wrapper now implements it, and models move between files. **Class names never change**, so import the generated barrel (`generated.dart`) rather than individual model files; the internal file layout is a function of the spec's `oneOf` graph and is not part of the public contract.
- **`oneOf` without a `discriminator` now decodes instead of throwing.** `fromJson` used to throw `UnimplementedError` unconditionally, which made those endpoints undecodable. It now tries the variants and returns the first that decodes, ordered most-specific-first — by number of required properties, then declared properties, then spec order. That order matters: `Customer{id}` is a subset of `Driver{id, license}`, and trying the narrow variant first would swallow every payload of the wide one. Two variants that accept the same payload remain genuinely ambiguous — add a `discriminator.propertyName` to decide explicitly.
- **Path and query parameters with `format: date-time` are now typed `DateTime`, not `String`.** The models already mapped that format to `DateTime`, so the same schema had two different Dart types depending on where it appeared. Parameters are now serialized with `toIso8601String()` before URL encoding. Known limitation: the `date_time_converter: timestamp` option is not yet honoured on parameters — it applies to model properties only.

### Changed

- **The non-200 primary-response warning is aggregated.** One warning per operation ("using 201 as primary response") produced dozens of lines on a large spec, for behaviour that is correct and needs no attention. A single line now reports the count and the operations concerned.
- **Object-typed path parameters warn.** They were interpolated as `toJson().toString()`, writing a Dart map literal into the URL; OpenAPI `style`/`explode` serialization is not implemented, so the case is now flagged like the array one.
- **A discriminator `mapping` pointing at an unregistered schema raises a readable `OpenApiParseException`** instead of a raw `StateError`.
- **Generated unions without a discriminator carry their own dartdoc**, stating the order in which variants are tried, that a variant's parse errors are swallowed, and that `discriminator.propertyName` is the way to decide explicitly. Previously that contract lived only in this changelog.
- **A collapsed single-branch `oneOf` keeps the wrapper's `description`** when the branch is inline and declares none of its own.

### Added

- **`oneOf` branches that are not objects are supported.** Array, primitive and enum branches used to be dropped with a warning, leaving the union without a case for them. They are now emitted as a generated class holding the decoded `value` (e.g. `final class GetPointsResponsePointList extends GetPointsResponse { final List<Point> value; }`). A union with such a branch cannot promise a JSON object, so its `toJson`/`fromJson` widen to `Object?` and the service call site stops typing the Dio response — unions of objects keep the narrower `Map<String, dynamic>` signature and are unchanged.
- **A single-branch `oneOf` written inline is collapsed to its branch.** `{ oneOf: [ { type: string } ] }` on a path parameter is a `String`; it no longer produces a `sealed` wrapper with one case. A *named* single-branch `oneOf` is left alone — collapsing it would make the component disappear.

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
