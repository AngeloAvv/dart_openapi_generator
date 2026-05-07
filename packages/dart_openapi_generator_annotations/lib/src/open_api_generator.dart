import 'package:meta/meta.dart';

import 'date_time_converter.dart';
import 'input_spec.dart';

/// Configuration annotation for [dart_openapi_generator](https://pub.dev/packages/dart_openapi_generator).
///
/// Place on any Dart class to trigger OpenAPI code generation via `build_runner`:
///
/// ```dart
/// import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';
///
/// @OpenApiGenerator(
///   inputSpec: LocalSpec('openapi/my_api.yaml'),
///   outputDir: 'lib/generated',
/// )
/// class $MyApp {}
/// ```
///
/// All optional fields have sensible defaults. See each field's documentation
/// for details.
@immutable
class OpenApiGenerator {
  /// The OpenAPI spec to generate from.
  ///
  /// Use [LocalSpec] for a local file path or [RemoteSpec] for a URL.
  final InputSpec inputSpec;

  /// Directory where generated Dart files are written, relative to the
  /// package root.
  ///
  /// Example: `'lib/generated'`
  final String outputDir;

  /// Name of the top-level aggregator client class.
  ///
  /// Defaults to `'ApiClient'`. Use a descriptive name that matches your API
  /// (e.g. `'PetstoreClient'`).
  final String clientName;

  /// Whether to skip code generation when the spec has not changed since the
  /// last run.
  ///
  /// If `true` (the default), the generator computes an MD5 cache key from
  /// the spec bytes, generator version, and annotation config. On a cache hit
  /// the build step is a no-op, keeping incremental builds fast.
  /// If `false`, generation always runs regardless of cache.
  final bool skipIfSpecIsUnchanged;

  /// Directory where the spec cache is stored, relative to the package root.
  ///
  /// Defaults to `'.dart_tool/dart_openapi_generator_cache'`. Changing this
  /// value invalidates any existing cache.
  final String cachePath;

  /// Whether to delete previously-generated files before writing new output.
  ///
  /// If `true` (the default), files listed in the prior-run manifest are
  /// deleted before generation. Files not in the manifest are never touched.
  /// If `false`, stale generated files may accumulate; useful during
  /// debugging.
  final bool cleanOutput;

  /// Strategy for serializing `string` + `date-time` schema fields.
  ///
  /// Defaults to [DateTimeConverter.iso8601]. Set to
  /// [DateTimeConverter.timestamp] for milliseconds-since-epoch
  /// serialization.
  final DateTimeConverter dateTimeConverter;

  /// Whether to print verbose debug output during code generation.
  ///
  /// If `true`, the generator logs every file written, every file deleted,
  /// cache-hit/miss decisions, and parse warnings.
  /// If `false` (the default), only errors are printed.
  final bool debugLogging;

  /// Creates an [OpenApiGenerator] annotation.
  ///
  /// [inputSpec] and [outputDir] are required; all other fields have sensible
  /// defaults.
  const OpenApiGenerator({
    required this.inputSpec,
    required this.outputDir,
    this.clientName = 'ApiClient',
    this.skipIfSpecIsUnchanged = true,
    this.cachePath = '.dart_tool/dart_openapi_generator_cache',
    this.cleanOutput = true,
    this.dateTimeConverter = DateTimeConverter.iso8601,
    this.debugLogging = false,
  });
}
