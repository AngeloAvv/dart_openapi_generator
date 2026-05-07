# dart_openapi_generator

OpenAPI 3.x → Dart code generator for Flutter and Dart. Point it at a spec (YAML or JSON, local file or HTTPS URL) and get Dio-based model classes and API client services — generated via `build_runner`, no JVM, no Mustache, no runtime annotation libraries in your dependency tree.

## Packages

| Package | pub.dev | Description |
|---------|---------|-------------|
| [`dart_openapi_generator_annotations`](packages/dart_openapi_generator_annotations/) | [![pub](https://img.shields.io/pub/v/dart_openapi_generator_annotations.svg)](https://pub.dev/packages/dart_openapi_generator_annotations) | `@OpenApiGenerator`, `LocalSpec`, `RemoteSpec`, `DateTimeConverter` — zero runtime deps beyond `meta` |
| [`dart_openapi_generator`](packages/dart_openapi_generator/) | [![pub](https://img.shields.io/pub/v/dart_openapi_generator.svg)](https://pub.dev/packages/dart_openapi_generator) | `build_runner` builder (dev dependency only) |

## Documentation

Full documentation at **[docs.page/angeloavv/dart_openapi_generator](https://docs.page/angeloavv/dart_openapi_generator)**.

## Quick Start

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

Create a marker class in any Dart file and annotate it with `@OpenApiGenerator`:

```dart
import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';

@OpenApiGenerator(
  inputSpec: LocalSpec('openapi/api.yaml'),
  outputDir: 'lib/generated',
  clientName: 'MyApiClient',
)
class $MyApp {}
```

Then run:

```sh
dart run build_runner build
```

The generator writes all files directly into `lib/generated/`. No `part`/`part of` directives are used.

## What Gets Generated

For a spec with a `User` schema and a `users` tag, the generator produces:

```
lib/generated/
├── models/
│   └── user.dart          ← final class User with fromJson / toJson / copyWith / == / hashCode
├── services/
│   └── users_api.dart     ← class UsersApi wrapping a Dio instance
├── api_client.dart        ← MyApiClient with per-tag service accessors and auth interceptor factories
└── generated.dart         ← barrel export
```

### Model classes

Each `components/schemas` entry produces one file. Generated classes are `final` and carry no runtime dependencies:

```dart
// lib/generated/models/user.dart  (generated — do not edit)
final class User {
  final String id;
  final String name;
  final String email;
  final UserRole? role;
  final DateTime? createdAt;

  User({
    required this.id,
    required this.name,
    required this.email,
    this.role,
    this.createdAt,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] == null
            ? (throw ArgumentError.notNull('User.id'))
            : json['id'] as String,
        // ...
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        // ...
      };

  User copyWith({String? id, /* ... */}) => User(id: id ?? this.id, /* ... */);

  @override
  bool operator ==(Object other) => /* ... */;

  @override
  int get hashCode => Object.hash(id, name, email, role, createdAt);
}
```

### Service classes

One class per tag. Each method maps to one operation and accepts path parameters as positional arguments, query/header parameters as named arguments, plus optional Dio override params:

```dart
// lib/generated/services/users_api.dart  (generated — do not edit)
class UsersApi {
  final Dio _dio;
  const UsersApi(this._dio);

  Future<List<User>> listUsers({int? page, CancelToken? cancelToken, /* ... */}) async { /* ... */ }
  Future<User> createUser(User body, {CancelToken? cancelToken, /* ... */}) async { /* ... */ }
  Future<User> getUser(String id, {CancelToken? cancelToken, /* ... */}) async { /* ... */ }
  Future<void> deleteUser(String id, {CancelToken? cancelToken, /* ... */}) async { /* ... */ }
}
```

### API client barrel

The top-level client class exposes each tag as a named field and provides static auth interceptor factories derived from `securitySchemes`:

```dart
final client = MyApiClient(
  baseUrl: 'https://api.example.com/v1',
  interceptors: [
    MyApiClient.bearerAuth('your-token'),
  ],
);

final users = await client.users.listUsers();
final user  = await client.users.getUser('abc');
```

Auth factories generated from `securitySchemes`:

| Factory | Scheme type |
|---------|-------------|
| `MyApiClient.bearerAuth(token)` | `http` / `bearer` |
| `MyApiClient.basicAuth(user, password)` | `http` / `basic` |
| `MyApiClient.apiKeyAuth(key, headerName:)` | `apiKey` / `header` |
| `MyApiClient.apiKeyQueryAuth(key, paramName:)` | `apiKey` / `query` |

## Annotation Reference

```dart
@OpenApiGenerator(
  inputSpec: LocalSpec('openapi/api.yaml'),   // required — local file path relative to package root
  outputDir: 'lib/generated',                // required — output directory relative to package root
  clientName: 'ApiClient',                  // optional — name of the generated top-level class (default: 'ApiClient')
  skipIfSpecIsUnchanged: true,               // optional — skip generation on MD5 cache hit (default: true)
  cachePath: '.dart_tool/dart_openapi_generator_cache', // optional — cache directory (default shown)
  cleanOutput: true,                         // optional — delete previously generated files before writing (default: true)
  dateTimeConverter: DateTimeConverter.iso8601, // optional — iso8601 (default) or timestamp
  debugLogging: false,                       // optional — log every file written/deleted (default: false)
)
class $MyApp {}
```

### `InputSpec` variants

```dart
// Local file (path relative to pubspec.yaml)
inputSpec: LocalSpec('openapi/api.yaml')

// Remote HTTPS URL — HTTPS required, optional auth headers
inputSpec: RemoteSpec('https://petstore3.swagger.io/api/v3/openapi.json')
inputSpec: RemoteSpec(
  'https://example.com/api.json',
  headers: {'Authorization': 'Bearer token'},
)
```

### `DateTimeConverter`

| Value | `fromJson` | `toJson` |
|-------|-----------|---------|
| `DateTimeConverter.iso8601` (default) | `DateTime.parse(v as String)` | `.toIso8601String()` |
| `DateTimeConverter.timestamp` | `DateTime.fromMillisecondsSinceEpoch(v as int)` | `.millisecondsSinceEpoch` |

## Schema Type Support

| OpenAPI schema type | Generated Dart |
|---------------------|----------------|
| `object` | `final class` with named fields, `fromJson` / `toJson` / `copyWith` / `==` / `hashCode` |
| `enum` (string, integer, number) | Dart `enum` with `fromJson` / `toJson` |
| `allOf` | Flat-merged `final class` (properties from all `ObjectSchema` members combined) |
| `oneOf` with discriminator | `sealed class` parent + one `final class` per variant, switch-expression `fromJson` |
| Primitive (`string`, `integer`, `number`, `boolean`) | `typedef` alias |
| Array top-level | `typedef` alias to `List<T>` |
| `string` + `format: date-time` | `DateTime` (ISO 8601 or epoch per `dateTimeConverter`) |
| `additionalProperties` | `Map<String, T>` field (`additionalProperties` on the class) |

## Caching

When `skipIfSpecIsUnchanged: true` (the default), the generator computes an MD5 cache key from:

- Raw spec bytes
- Generator version
- Annotation fields that affect output (`outputDir`, `clientName`, `dateTimeConverter`, `cleanOutput`)

On a cache hit the build step is a no-op. Cache entries live under `cachePath` (default `.dart_tool/dart_openapi_generator_cache`) and are written atomically (temp-file rename) to survive concurrent `build_runner` invocations.

## Repository Structure

```
dart_openapi_generator/
├── packages/
│   ├── dart_openapi_generator_annotations/  ← annotation types (runtime dep)
│   │   └── lib/src/
│   │       ├── open_api_generator.dart      ← @OpenApiGenerator
│   │       ├── input_spec.dart              ← LocalSpec, RemoteSpec (sealed)
│   │       └── date_time_converter.dart     ← DateTimeConverter enum
│   └── dart_openapi_generator/              ← build_runner builder (dev dep)
│       └── lib/src/
│           ├── builder/                     ← OpenApiBuilder (build_runner entry)
│           ├── parser/                      ← OpenAPI 3.x YAML/JSON parser
│           ├── generator/                   ← ModelGenerator, ServiceGenerator, AggregatorGenerator
│           ├── writer/                      ← FileWriter (format, clean, manifest)
│           ├── spec_loader.dart             ← LocalSpecLoader, RemoteSpecLoader
│           └── cache_manager.dart           ← MD5 cache keying + atomic writes
├── example/                                 ← consumer project exercising v0.1.0 features
│   ├── openapi/example_api.yaml
│   └── lib/
│       ├── main.dart                        ← @OpenApiGenerator marker + usage example
│       └── generated/                       ← regenerated by CI
├── docs/                                    ← docs.page MDX source
└── pubspec.yaml                             ← pub workspace root
```

## Running Tests

```sh
dart test packages/dart_openapi_generator_annotations/test/
dart test packages/dart_openapi_generator/test/
```

End-to-end validation with the example project:

```sh
cd example
dart pub get
dart run build_runner build --delete-conflicting-outputs
dart analyze lib/generated/
```

## Contributing

1. Fork the repository and create a feature branch.
2. Keep `dart analyze` clean and `dart format` idempotent.
3. Add or update tests for any changed behaviour. Run `dart test` in each affected package.
4. Open a pull request describing what changed and why.

Bug reports and feature requests: [issue tracker](https://github.com/AngeloAvv/dart_openapi_generator/issues).

## License

MIT — see [LICENSE](LICENSE).
