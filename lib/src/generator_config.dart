import 'package:build/build.dart';

import 'date_time_converter.dart';
import 'model_class_modifier.dart';

/// Resolved builder configuration, sourced from the `options:` block of the
/// consumer's `build.yaml` (via [BuilderOptions.config]) rather than a Dart
/// annotation — config must be readable synchronously in the builder
/// factory, before any Dart element resolution is possible.
final class GeneratorConfig {
  final String inputSpec;
  final String outputDir;
  final String clientName;
  final DateTimeConverter dateTimeConverter;
  final ModelClassModifier modelClassModifier;
  final bool debugLogging;

  const GeneratorConfig({
    required this.inputSpec,
    required this.outputDir,
    required this.clientName,
    required this.dateTimeConverter,
    required this.modelClassModifier,
    required this.debugLogging,
  });

  factory GeneratorConfig.fromBuilderOptions(BuilderOptions options) {
    final config = options.config;

    final inputSpec = config['input_spec'];
    if (inputSpec is! String || inputSpec.isEmpty) {
      throw ArgumentError(
        'dart_openapi_generator: "input_spec" must be set to a non-empty '
        'local spec file path in build.yaml, e.g.\n'
        '  targets:\n'
        '    \$default:\n'
        '      builders:\n'
        '        dart_openapi_generator:\n'
        '          options:\n'
        '            input_spec: "openapi/spec.yaml"\n'
        '            output_dir: "lib/generated"',
      );
    }

    final outputDir = config['output_dir'];
    if (outputDir is! String || outputDir.isEmpty) {
      throw ArgumentError(
        'dart_openapi_generator: "output_dir" must be set to a non-empty '
        'path in build.yaml options.',
      );
    }

    return GeneratorConfig(
      inputSpec: inputSpec,
      outputDir: outputDir,
      clientName: (config['client_name'] as String?) ?? 'ApiClient',
      dateTimeConverter: _readDateTimeConverter(config['date_time_converter']),
      modelClassModifier: _readModelClassModifier(
        config['model_class_modifier'],
      ),
      debugLogging: (config['debug_logging'] as bool?) ?? false,
    );
  }

  static DateTimeConverter _readDateTimeConverter(Object? raw) {
    if (raw == null) return DateTimeConverter.iso8601;
    if (raw is! String) {
      throw ArgumentError(
        'dart_openapi_generator: "date_time_converter" must be a string '
        '(one of ${DateTimeConverter.values.map((v) => v.name).join(', ')}), '
        'got: $raw',
      );
    }
    try {
      return DateTimeConverter.values.byName(raw);
    } on ArgumentError {
      throw ArgumentError(
        'dart_openapi_generator: unknown "date_time_converter" value "$raw". '
        'Expected one of: ${DateTimeConverter.values.map((v) => v.name).join(', ')}',
      );
    }
  }

  static const _modelClassModifierNames = <String, ModelClassModifier>{
    'final': ModelClassModifier.final$,
    'none': ModelClassModifier.none,
  };

  static ModelClassModifier _readModelClassModifier(Object? raw) {
    if (raw == null) return ModelClassModifier.final$;
    final valid = _modelClassModifierNames.keys.join(', ');
    if (raw is! String) {
      throw ArgumentError(
        'dart_openapi_generator: "model_class_modifier" must be a string '
        '(one of $valid), got: $raw',
      );
    }
    final value = _modelClassModifierNames[raw];
    if (value == null) {
      throw ArgumentError(
        'dart_openapi_generator: unknown "model_class_modifier" value "$raw". '
        'Expected one of: $valid',
      );
    }
    return value;
  }
}
