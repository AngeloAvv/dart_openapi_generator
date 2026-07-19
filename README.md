# dart_openapi_generator

[![pub](https://img.shields.io/pub/v/dart_openapi_generator.svg)](https://pub.dev/packages/dart_openapi_generator)

A native-Dart `build_runner` builder that reads a local OpenAPI 3.x spec and generates Dio-based model classes and API service classes. No Mustache templates. Generated code looks like hand-written Dart.

Add as a **dev dependency** only — it is never in your app's runtime dependency tree.

## Documentation

Full documentation at **[docs.page/angeloavv/dart_openapi_generator](https://docs.page/angeloavv/dart_openapi_generator)**.

## How it works

1. `build_runner` invokes the `dartOpenApiBuilder` factory once, synchronously — before it freezes its asset graph for the invocation.
2. The factory reads `input_spec`/`output_dir` and other options from your `build.yaml`, loads the spec from disk (local files only — no HTTPS), and runs the full pipeline: parse into an internal document model (schemas, operations, security schemes), then `ModelGenerator`, `ServiceGenerator`, `AggregatorGenerator` emit Dart source, formatted with `dart_style`.
3. The resulting `Builder` instance's `buildExtensions` declares the real, per-project list of output files computed in step 2 — so build_runner tracks every generated file in its asset graph from the start.
4. `build()` itself just writes the precomputed files via `buildStep.writeAsString` — since they're declared outputs, downstream builders (e.g. your own `source_gen`-based builder) resolve them correctly in the same `build_runner build` invocation, no second pass needed.

Caching and cleanup of stale outputs are handled by build_runner's own incremental engine and `--delete-conflicting-outputs` — nothing to configure. See `HANDOVER-single-pass-build.md` for the full incident writeup behind this design.

## Installation

```yaml
# pubspec.yaml
dependencies:
  dio: ^5.0.0

dev_dependencies:
  dart_openapi_generator: ^0.2.0
  build_runner: ^2.4.0
```

## Setup

Configure the builder in your project's `build.yaml`:

```yaml
# build.yaml
targets:
  $default:
    builders:
      dart_openapi_generator:
        options:
          input_spec: "openapi/my_api.yaml"
          output_dir: "lib/generated"
          client_name: "MyApiClient"
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

All parameters are set in the `options:` block of your `build.yaml` (see [Setup](#setup)).

| Option | Type | Default | Description |
|-----------|------|---------|-------------|
| `input_spec` | `String` | required | Local spec file path, relative to package root. No remote/HTTPS spec URLs. |
| `output_dir` | `String` | required | Directory for generated files, relative to package root. The barrel file is named after this path's last segment — see [Generated output structure](#generated-output-structure). |
| `client_name` | `String` | `'ApiClient'` | Name of the generated aggregator class |
| `date_time_converter` | `String` | `'iso8601'` | `'iso8601'` → ISO 8601 strings; `'timestamp'` → milliseconds since epoch |
| `debug_logging` | `bool` | `false` | Log every file prepared |

Why `build.yaml` and not a Dart annotation: `input_spec`/`output_dir` must be readable **synchronously**, in the builder factory, before build_runner freezes its asset graph — annotation resolution requires a build already in progress, so it can't run early enough. See [How it works](#how-it-works).

## Generated output structure

Given `output_dir: 'lib/generated'`, the builder writes:

```
lib/generated/
  generated.dart          # barrel — exports everything below, named after output_dir's last segment
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

The barrel file's name is derived from `output_dir`'s last path segment, not hardcoded — this keeps multiple generated clients in the same app collision-free. For example, `output_dir: "lib/services/network/petstore_client"` produces `lib/services/network/petstore_client/petstore_client.dart`, not `generated.dart`.

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

`anyOf` is not supported and causes a build error.

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

The aggregator class (named by `client_name`) holds a `Dio` instance and one `late final` field per tag pointing to the corresponding service class.

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
| Spec sources | Local file only — no remote/HTTPS spec URLs |
| `$ref` | Same-file `$ref` only (`#/components/schemas/...`) |
| Primitive types | `string`, `integer`, `number`, `boolean` |
| Formats | `date-time` → `DateTime` (via `date_time_converter`); all other formats ignored |
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
| `anyOf` | Not supported; causes a build error |
| `securitySchemes` | `bearer`, `basic`, `apiKey` (header and query) |
| Path parameters | Supported; URI-encoded via `Uri.encodeComponent` |
| Query parameters | Supported (required and optional) |
| Header parameters | Supported (required and optional) |
| Cookie parameters | Not supported; build warning emitted |
| Request body | `application/json` schema resolved to a typed `body` parameter |
| Response types | Primary 2xx response body (200 preferred) |
| Tags | One service class per tag; untagged ops → `DefaultApi` |
| OpenAPI 3.2 non-standard verbs | Emitted as stubs using `_dio.request(options: Options(method: '...'))` |

## Caching and rebuilds

There is no bespoke cache layer — the spec is re-parsed synchronously on every `build_runner build` invocation (cheap: pure in-memory YAML/JSON parsing), but build_runner's own incremental engine (asset digests) skips re-formatting and re-writing unchanged output, and `--delete-conflicting-outputs` cleans up stale files. Nothing to configure or delete to force a rebuild — `build_runner build` always reflects the current spec.

## Repository Structure

```
dart_openapi_generator/
├── lib/src/
│   ├── builder/                     ← OpenApiBuilder (build_runner entry)
│   ├── generator_config.dart        ← GeneratorConfig, sourced from build.yaml options
│   ├── date_time_converter.dart     ← DateTimeConverter enum
│   ├── parser/                      ← OpenAPI 3.x YAML/JSON parser
│   ├── generator/                   ← ModelGenerator, ServiceGenerator, AggregatorGenerator
│   ├── writer/                      ← FileWriter (format + barrel)
│   └── spec_loader.dart             ← readLocalSpec (sync)
├── test/                            ← generator test suite
├── example/                         ← consumer project exercising current features
│   ├── openapi/example_api.yaml
│   ├── build.yaml                   ← builder options
│   └── lib/
│       ├── main.dart                ← usage example
│       └── generated/               ← regenerated by CI
├── docs/                            ← docs.page MDX source
└── pubspec.yaml                     ← the package itself + pub workspace root (example/ is the only member)
```

## Running Tests

```sh
dart test
```

End-to-end validation with the example project:

```sh
cd example
dart pub get
dart run build_runner build --delete-conflicting-outputs
dart analyze lib/generated/
```

## Example

The `example/` directory in the [repository](https://github.com/AngeloAvv/dart_openapi_generator) demonstrates a complete setup:

- `example/openapi/example_api.yaml` — the spec
- `example/build.yaml` — builder options
- `example/lib/main.dart` — usage example
- `example/lib/generated/` — the committed generated output

## Contributing

1. Fork the repository and create a feature branch.
2. Keep `dart analyze` clean and `dart format` idempotent.
3. Add or update tests for any changed behaviour. Run `dart test`.
4. Open a pull request describing what changed and why.

Bug reports and feature requests: [issue tracker](https://github.com/AngeloAvv/dart_openapi_generator/issues).

## License

MIT — see [LICENSE](LICENSE).
