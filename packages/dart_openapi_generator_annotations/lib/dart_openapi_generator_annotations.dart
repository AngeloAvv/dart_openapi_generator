/// Annotation types for [dart_openapi_generator](https://pub.dev/packages/dart_openapi_generator).
///
/// Import this library and annotate any Dart class with [@OpenApiGenerator]
/// to trigger OpenAPI code generation via `build_runner`:
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
library;

export 'src/date_time_converter.dart';
export 'src/input_spec.dart';
export 'src/open_api_generator.dart';
