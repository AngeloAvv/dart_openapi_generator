# dart_openapi_generator

[![pub](https://img.shields.io/pub/v/dart_openapi_generator.svg)](https://pub.dev/packages/dart_openapi_generator)

A native-Dart `build_runner` builder that reads an OpenAPI 3.x spec and generates Dio-based model classes and API service classes. No JVM, no Mustache templates. Generated code looks like hand-written Dart.

Add as a **dev dependency** only — it is never in your app's runtime dependency tree.

## How it works

1. `build_runner` discovers any Dart file annotated with `@OpenApiGenerator`.
2. The builder loads the spec (local file or HTTPS URL).
3. An MD5 cache key is computed from the spec bytes, generator version, and relevant annotation fields. If `skipIfSpecIsUnchanged: true` and the key matches a prior run, the step is a no-op.
4. The spec is parsed into an internal document model (schemas, operations, security schemes).
5. Three generators emit Dart source: `ModelGenerator`, `ServiceGenerator`, `AggregatorGenerator`.
6. All emitted files are formatted with `dart_style` before being written to `outputDir`.
7. A sentinel `.openapi_generator.g.dart` file is written next to the annotated source file so `build_runner` tracks the output.

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

## Setup

Annotate a marker class in your project with `@OpenApiGenerator`:

```dart
// lib/api_config.dart
import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';

@OpenApiGenerator(
  inputSpec: LocalSpec('openapi/my_api.yaml'),
  outputDir: 'lib/generated',
  clientName: 'MyApiClient',
)
class $MyApp {}
```

Run generation:

```sh
dart run build_runner build
```

Or watch for changes:

```sh
dart run build_runner watch
```

## Configuration reference

All parameters are set on the `@OpenApiGenerator` annotation.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `inputSpec` | `InputSpec` | required | `LocalSpec('path/to/spec.yaml')` or `RemoteSpec('https://...')` |
| `outputDir` | `String` | required | Directory for generated files, relative to package root |
| `clientName` | `String` | `'ApiClient'` | Name of the generated aggregator class |
| `skipIfSpecIsUnchanged` | `bool` | `true` | Skip generation on cache hit (MD5 of spec bytes + version + config) |
| `cachePath` | `String` | `'.dart_tool/dart_openapi_generator_cache'` | Cache directory, relative to package root |
| `cleanOutput` | `bool` | `true` | Delete files from prior runs (tracked in a manifest) before writing |
| `dateTimeConverter` | `DateTimeConverter` | `DateTimeConverter.iso8601` | `iso8601` → ISO 8601 strings; `timestamp` → milliseconds since epoch |
| `debugLogging` | `bool` | `false` | Log every file written, deleted, and cache decision |

See [`dart_openapi_generator_annotations`](https://pub.dev/packages/dart_openapi_generator_annotations) for full parameter documentation including `LocalSpec` and `RemoteSpec` fields.

## Generated output structure

Given `outputDir: 'lib/generated'`, the builder writes:

```
lib/generated/
  generated.dart          # barrel — exports everything below
  api_client.dart         # aggregator class with one field per tag + auth factories
  models/
    user.dart             # one file per OpenAPI component schema
    user_role.dart
    ...
  services/
    users_api.dart        # one file per tag (or 'default_api.dart' for untagged ops)
    auth_api.dart
    ...
```

A sentinel file is also written next to your annotated source:

```
lib/api_config.openapi_generator.g.dart   # build_runner tracking — do not import
```

## Generated model classes

Each `object` schema in `components/schemas` becomes a `final class` with:

- `final` fields for every property (nullable or non-nullable based on the `required` list)
- Named constructor (`const` when all fields are primitives or enums with no `DateTime` / `List` / `Map`)
- `factory fromJson(Map<String, dynamic> json)` — throws `ArgumentError` for missing required fields
- `Map<String, dynamic> toJson()`
- `copyWith(...)` — nullable fields use an `_Undefined` sentinel to distinguish `null` from "not provided"
- `operator ==` and `hashCode` — list fields use element-by-element comparison; map fields use key-by-key comparison

Example (from the example project's `User` schema):

```dart
final class User {
  final String email;
  final String id;
  final String name;
  final UserRole? role;
  final DateTime? createdAt;

  User({
    required this.email,
    required this.id,
    required this.name,
    this.role,
    this.createdAt,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        email: json['email'] == null
            ? (throw ArgumentError.notNull('User.email'))
            : json['email'] as String,
        // ...
      );

  Map<String, dynamic> toJson() => {
        'email': email,
        // ...
        if (role != null) 'role': role!.toJson(),
      };

  User copyWith({String? email, /* ... */}) => User(/* ... */);

  @override
  bool operator ==(Object other) => /* ... */;

  @override
  int get hashCode => Object.hash(/* ... */);
}
```

### Other schema kinds

| OpenAPI schema | Generated output |
|----------------|-----------------|
| `type: object` | `final class` with the members above |
| `type: string/integer/number/boolean` (top-level) | `typedef Name = DartType;` |
| `type: array` (top-level) | `typedef Name = List<ItemType>;` |
| `enum` | Dart `enum` with `static Name fromJson(T v)` and `T toJson()` methods |
| `allOf` | Flat-merged `final class` (properties from all `object` members combined) |
| `oneOf` with `discriminator` | `sealed class` parent + one `final class` per variant; `fromJson` dispatches via switch expression on the discriminator property |
| `additionalProperties` | `Map<String, V>` field named `additionalProperties` |

`anyOf` is not supported in v0.1.0 and causes a build error.

## Generated service classes

Each OpenAPI tag produces one class. Operations within a tag are sorted alphabetically by derived method name. Untagged operations go into `DefaultApi`.

Each method receives:

- Path parameters as positional required arguments (in path-template order)
- Required request body as a positional required argument named `body`
- Query parameters as named arguments (`required` or optional matching the spec)
- Header parameters as named `String` / `String?` arguments
- Dio override parameters: `cancelToken`, `headers`, `extra`, `validateStatus`
- `onSendProgress` (omitted for GET, HEAD, DELETE, OPTIONS)
- `onReceiveProgress` (omitted for HEAD and DELETE)

Return types are derived from the primary 2xx response (`200` preferred, then `201`, then the lowest 2xx code). Operations with no 2xx response return `Future<void>`.

Example (from the example project):

```dart
class UsersApi {
  final Dio _dio;
  const UsersApi(this._dio);

  Future<User> createUser(
    User body, {
    CancelToken? cancelToken,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? extra,
    ValidateStatus? validateStatus,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async { /* ... */ }

  Future<List<User>> listUsers({
    int? page,
    CancelToken? cancelToken,
    // ...
  }) async { /* ... */ }
}
```

Cookie parameters are not supported. A build warning is emitted and the parameter is omitted. Use Dio interceptors for cookie-based auth.

## Generated aggregator class

The aggregator class (named by `clientName`) holds a `Dio` instance and one `late final` field per tag pointing to the corresponding service class.

```dart
class MyApiClient {
  late Dio _dio;
  static const String _defaultBaseUrl = 'https://api.example.com/v1';

  late final UsersApi users = UsersApi(_dio);
  // ... one field per tag

  MyApiClient({
    Dio? dio,
    String? baseUrl,
    List<Interceptor>? interceptors,
    Duration connectTimeout = const Duration(seconds: 30),
    Duration receiveTimeout = const Duration(seconds: 30),
  }) { /* initializes _dio */ }
}
```

### Auth helper factories

Static factory methods are generated from `components/securitySchemes`. Each method returns an `Interceptor` that you pass via the `interceptors` constructor parameter.

| Scheme type | Generated factory | Signature |
|-------------|------------------|-----------|
| `http` + `scheme: bearer` | `bearerAuth` | `static Interceptor bearerAuth(String token)` |
| `http` + `scheme: basic` | `basicAuth` | `static Interceptor basicAuth(String username, String password)` |
| `apiKey` + `in: header` | `apiKeyAuth` | `static Interceptor apiKeyAuth(String apiKey, {String headerName = 'X-Api-Key'})` |
| `apiKey` + `in: query` | `apiKeyQueryAuth` | `static Interceptor apiKeyQueryAuth(String apiKey, {String paramName = 'api_key'})` |

```dart
final client = MyApiClient(
  interceptors: [
    MyApiClient.bearerAuth('your-token'),
  ],
);
```

## Supported OpenAPI features

| Feature | Support |
|---------|---------|
| OpenAPI version | 3.x only (3.0, 3.1, 3.2). Version 2 (Swagger) is rejected. |
| Spec formats | YAML and JSON |
| Spec sources | Local file (`LocalSpec`) and HTTPS URL (`RemoteSpec`) |
| `$ref` | Same-file `$ref` only (`#/components/schemas/...`) |
| Primitive types | `string`, `integer`, `number`, `boolean` |
| Formats | `date-time` → `DateTime` (via `dateTimeConverter`); all other formats ignored |
| `type: null` | Parsed as `NullSchema`; top-level null schemas produce no file |
| `nullable: true` (3.0) | Supported |
| `type: [T, 'null']` (3.1) | Supported |
| Mixed nullable styles | Rejected with a parse error |
| `enum` | Supported for `string`, `integer`, `number` types |
| `object` with `properties` | Supported |
| `object` with `additionalProperties` | Supported (bool or typed schema) |
| Implicit object (no `type`, no composition keyword) | Treated as `object` |
| `array` with `items` | Supported |
| `allOf` | Flat merge of all `object` members |
| `oneOf` with `discriminator` | Sealed class + switch expression dispatch |
| `oneOf` without `discriminator` | Parsed but `fromJson` throws `UnimplementedError` |
| `anyOf` | Not supported in v0.1.0; causes a build error |
| `securitySchemes` | `bearer`, `basic`, `apiKey` (header and query) |
| Path parameters | Supported; URI-encoded via `Uri.encodeComponent` |
| Query parameters | Supported (required and optional) |
| Header parameters | Supported (required and optional) |
| Cookie parameters | Not supported; build warning emitted |
| Request body | `application/json` schema resolved to a typed `body` parameter |
| Response types | Primary 2xx response body (200 preferred) |
| Tags | One service class per tag; untagged ops → `DefaultApi` |
| OpenAPI 3.2 non-standard verbs | Emitted as stubs using `_dio.request(options: Options(method: '...'))` |

## Cache behavior

When `skipIfSpecIsUnchanged: true` (the default), the builder computes an MD5 cache key from:

- MD5 of the raw spec bytes
- The generator version string (`0.1.0`)
- A canonical JSON object containing `outputDir`, `clientName`, `dateTimeConverter`, and `cleanOutput`

Fields that do not affect generated output (`debugLogging`, `skipIfSpecIsUnchanged`, `cachePath`) are excluded from the key.

On a cache hit, the build step exits immediately without parsing or writing any files. Cache entries are written atomically (temp file + rename) to survive concurrent `build_runner` invocations.

To force a full rebuild: delete `.dart_tool/dart_openapi_generator_cache/` or set `skipIfSpecIsUnchanged: false`.

## Example

The `example/` directory in the [repository](https://github.com/AngeloAvv/dart_openapi_generator) demonstrates a complete setup:

- `example/openapi/example_api.yaml` — the spec
- `example/lib/main.dart` — the annotated marker class and usage example
- `example/lib/generated/` — the committed generated output

## Links

- [`dart_openapi_generator_annotations`](https://pub.dev/packages/dart_openapi_generator_annotations) — annotation types (runtime dependency)
- [GitHub repository](https://github.com/AngeloAvv/dart_openapi_generator)
- [Issue tracker](https://github.com/AngeloAvv/dart_openapi_generator/issues)
