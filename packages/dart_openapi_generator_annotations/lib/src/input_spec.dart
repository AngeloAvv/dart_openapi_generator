import 'package:meta/meta.dart';

/// The source of the OpenAPI specification.
///
/// Use [LocalSpec] for a file on disk:
///
/// ```dart
/// @OpenApiGenerator(inputSpec: LocalSpec('openapi/my_api.yaml'), ...)
/// class $MyApp {}
/// ```
///
/// Use [RemoteSpec] to fetch from a URL:
///
/// ```dart
/// @OpenApiGenerator(
///   inputSpec: RemoteSpec(
///     'https://petstore3.swagger.io/api/v3/openapi.json',
///     headers: {'Authorization': 'Bearer token'},
///   ),
///   ...
/// )
/// class $MyApp {}
/// ```
@immutable
sealed class InputSpec {
  const InputSpec();
}

/// A local file path to an OpenAPI spec.
///
/// [path] is relative to the package root (where `pubspec.yaml` lives).
///
/// ```dart
/// const spec = LocalSpec('openapi/my_api.yaml');
/// ```
@immutable
final class LocalSpec extends InputSpec {
  /// Path to the spec file, relative to the package root.
  final String path;

  /// Creates a [LocalSpec] pointing at [path].
  const LocalSpec(this.path);
}

/// A remote URL pointing to an OpenAPI spec.
///
/// [url] must use the `https` scheme. [headers] are optional HTTP request
/// headers (e.g. for authenticated specs). Auth header values are never
/// logged regardless of [OpenApiGenerator.debugLogging].
///
/// ```dart
/// const spec = RemoteSpec('https://example.com/api.json');
/// const authSpec = RemoteSpec(
///   'https://example.com/api.json',
///   headers: {'Authorization': 'Bearer my-token'},
/// );
/// ```
@immutable
final class RemoteSpec extends InputSpec {
  /// HTTPS URL of the OpenAPI spec.
  final String url;

  /// Optional HTTP headers sent with the fetch request.
  ///
  /// `null` (the default) means no extra headers are sent. Pass an explicit
  /// empty map `{}` only if your server requires it.
  final Map<String, String>? headers;

  /// Creates a [RemoteSpec] for [url] with optional [headers].
  const RemoteSpec(this.url, {this.headers});
}
