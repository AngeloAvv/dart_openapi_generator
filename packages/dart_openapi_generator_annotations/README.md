# dart_openapi_generator_annotations

[![pub](https://img.shields.io/pub/v/dart_openapi_generator_annotations.svg)](https://pub.dev/packages/dart_openapi_generator_annotations)

Annotation types for [`dart_openapi_generator`](https://pub.dev/packages/dart_openapi_generator). Place `@OpenApiGenerator` on a Dart class to configure OpenAPI 3.x → Dart code generation via `build_runner`.

This package defines the annotation types only. It does nothing at runtime. Pair it with `dart_openapi_generator` as a dev dependency to run generation.

## Exports

| Name | Kind | Description |
|------|------|-------------|
| `OpenApiGenerator` | class | Annotation that configures code generation |
| `InputSpec` | sealed class | Discriminated union for the spec source |
| `LocalSpec` | final class | Reads the spec from a local file |
| `RemoteSpec` | final class | Fetches the spec from an HTTPS URL |
| `DateTimeConverter` | enum | Controls `DateTime` serialization strategy |

## Installation

```yaml
# pubspec.yaml
dependencies:
  dart_openapi_generator_annotations: ^0.1.0
  dio: ^5.0.0

dev_dependencies:
  dart_openapi_generator: ^0.1.0
  build_runner: ^2.4.0
```

## Usage

```dart
import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';

@OpenApiGenerator(
  inputSpec: LocalSpec('openapi/my_api.yaml'),
  outputDir: 'lib/generated',
)
class $MyApp {}
```

Then run:

```sh
dart run build_runner build
```

Only one `@OpenApiGenerator` annotation per file is processed. If multiple are present, a build warning is emitted and only the first is used.

## `@OpenApiGenerator` parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `inputSpec` | `InputSpec` | required | Spec source — `LocalSpec` or `RemoteSpec` |
| `outputDir` | `String` | required | Directory for generated files, relative to package root (e.g. `'lib/generated'`) |
| `clientName` | `String` | `'ApiClient'` | Name of the generated aggregator class |
| `skipIfSpecIsUnchanged` | `bool` | `true` | Skip generation when the spec and relevant config have not changed since the last run. Uses an MD5-keyed cache stored at `cachePath`. |
| `cachePath` | `String` | `'.dart_tool/dart_openapi_generator_cache'` | Directory where the build cache is stored, relative to the package root. Changing this path invalidates any existing cache entries. |
| `cleanOutput` | `bool` | `true` | Delete previously generated files (tracked in a manifest) before writing new output. Set to `false` to keep stale files during debugging. |
| `dateTimeConverter` | `DateTimeConverter` | `DateTimeConverter.iso8601` | Serialization strategy for `string`+`format: date-time` schema fields |
| `debugLogging` | `bool` | `false` | Log every file written, deleted, and cache-hit/miss decision. Auth header values are never logged regardless of this setting. |

## `InputSpec`

`InputSpec` is a sealed class. Use one of its two subtypes:

### `LocalSpec(String path)`

Reads the spec from a local file. `path` is relative to the package root (the directory containing `pubspec.yaml`).

```dart
@OpenApiGenerator(
  inputSpec: LocalSpec('openapi/my_api.yaml'),
  outputDir: 'lib/generated',
)
class $MyApp {}
```

### `RemoteSpec(String url, {Map<String, String>? headers})`

Fetches the spec from an HTTPS URL. Only `https` scheme is accepted — `http` URLs are rejected before any network request is made. A 30-second timeout is enforced. Auth header values are never written to any log.

```dart
@OpenApiGenerator(
  inputSpec: RemoteSpec(
    'https://petstore3.swagger.io/api/v3/openapi.json',
    headers: {'Authorization': 'Bearer my-token'},
  ),
  outputDir: 'lib/generated',
)
class $MyApp {}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `url` | `String` | required | HTTPS URL of the OpenAPI spec |
| `headers` | `Map<String, String>?` | `null` | Optional HTTP request headers sent with the fetch |

## `DateTimeConverter`

Controls how `string`+`format: date-time` fields are handled in generated `fromJson` / `toJson` methods.

| Value | `fromJson` expression | `toJson` expression |
|-------|-----------------------|---------------------|
| `DateTimeConverter.iso8601` (default) | `DateTime.parse(json['field'] as String)` | `field.toIso8601String()` |
| `DateTimeConverter.timestamp` | `DateTime.fromMillisecondsSinceEpoch(json['field'] as int)` | `field.millisecondsSinceEpoch` |

## Dependencies

The only dependency of this package is `meta: ^1.17.0`, used for the `@immutable` annotation on `OpenApiGenerator` and `InputSpec`.

## Links

- [`dart_openapi_generator`](https://pub.dev/packages/dart_openapi_generator) — the `build_runner` builder (dev dependency)
- [GitHub repository](https://github.com/AngeloAvv/dart_openapi_generator)
- [Issue tracker](https://github.com/AngeloAvv/dart_openapi_generator/issues)
