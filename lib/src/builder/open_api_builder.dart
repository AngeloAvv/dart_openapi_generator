import 'package:build/build.dart';

import '../generator/aggregator_generator.dart';
import '../generator/model_generator.dart';
import '../generator/service_generator.dart';
import '../generator_config.dart';
import '../layout/model_layout.dart';
import '../layout/one_of_plan.dart';
import '../name_registry/name_converter.dart';
import '../name_registry/name_registry.dart';
import '../parser/openapi_parser.dart';
import '../parser/spec_sniffer.dart';
import '../parser/version_validator.dart';
import '../spec_loader.dart';
import '../writer/file_writer.dart';

/// Build-time generator that emits model classes, service classes, and the
/// aggregator client for the OpenAPI spec configured in `build.yaml`.
///
/// Unlike a typical [Builder], the entire codegen pipeline (spec read, parse,
/// generate, format) already ran **synchronously in the builder factory**
/// (see `dartOpenApiBuilder` in `lib/builder.dart`) before this instance was
/// constructed — that's what let [buildExtensions] declare the real,
/// project-specific list of output files up front, so build_runner tracks
/// them in its asset graph. [build] itself is purely mechanical: it writes
/// the precomputed [outputFiles] via [BuildStep.writeAsString].
final class OpenApiBuilder implements Builder {
  final GeneratorConfig config;

  /// Precomputed at factory time: relative path (under [config.outputDir])
  /// → final formatted Dart source.
  final Map<String, String> outputFiles;

  /// Warnings collected while [generateFiles] ran in the builder factory
  /// (before a [BuildStep]/`log` zone existed). Flushed to `log.warning` in
  /// [build], which does run inside build_runner's logging zone.
  final List<String> warnings;

  const OpenApiBuilder(this.config, this.outputFiles, this.warnings);

  /// Runs the full codegen pipeline synchronously and returns the finished
  /// `{relativePath: formattedSource}` map plus any advisory warnings raised
  /// along the way. Called once, from the builder factory, before any
  /// [OpenApiBuilder] is constructed.
  static ({Map<String, String> files, List<String> warnings}) generateFiles(
    GeneratorConfig config,
  ) {
    final warnings = <String>[];
    void onWarning(String message) => warnings.add(message);

    final specBytes = readLocalSpec(config.inputSpec);

    final sniffResult = sniffSpec(specBytes);
    final sniffSourceMap = switch (sniffResult) {
      YamlSniffResult(:final sourceMap) => sourceMap,
      JsonSniffResult(:final sourceMap) => sourceMap,
    };
    validateVersion(sniffResult.map['openapi'] as String?, sniffSourceMap);
    final parseResult = parseSpec(sniffResult.map, sniffSourceMap);

    // Classify every `oneOf` branch once; the registry, the layout and both
    // generators all read that single plan.
    final oneOfPlan = OneOfPlan.build(parseResult.document);
    final registry = buildNameRegistry(
      parseResult.document,
      oneOfPlan: oneOfPlan,
    );
    final layout = ModelLayout.build(
      parseResult.document,
      registry,
      oneOfPlan: oneOfPlan,
    );
    final modelFiles = ModelGenerator(
      registry,
      layout,
      config.dateTimeConverter,
      onWarning: onWarning,
    ).generate(parseResult.document);
    final serviceFiles = ServiceGenerator(
      registry,
      layout,
      onWarning: onWarning,
    ).generate(parseResult.document);
    final aggregatorFiles = AggregatorGenerator(
      onWarning: onWarning,
    ).generate(parseResult.document, config);

    final allFiles = {...modelFiles, ...serviceFiles, ...aggregatorFiles};
    final files = FileWriter(
      onLog: config.debugLogging ? onWarning : null,
      onWarning: onWarning,
    ).prepare(
      allFiles,
      barrelFileName: '${barrelBaseName(config.outputDir)}.dart',
    );
    return (files: files, warnings: warnings);
  }

  /// Derives the barrel file's base name (without `.dart`) from `outputDir`'s
  /// last path segment — e.g. `lib/services/network/petstore_client` →
  /// `petstore_client`. Reuses [tagToSnake]'s sanitizer (lowercase, spaces
  /// and hyphens → underscore) since the requirement is identical: turn an
  /// arbitrary human-chosen string into a valid snake_case file name.
  static String barrelBaseName(String outputDir) {
    final normalized =
        outputDir.endsWith('/')
            ? outputDir.substring(0, outputDir.length - 1)
            : outputDir;
    final lastSegment = normalized.split('/').last;
    return tagToSnake(lastSegment);
  }

  // Keyed on the `$package$` synthetic input (not the spec file path):
  // build_runner selects which builder invocations to run for a given input
  // from the STATIC `build_extensions` declared in build.yaml, not from this
  // runtime getter — and that static declaration must also use `$package$`
  // (it can't know the spec path ahead of time). The two must agree, or
  // build_runner runs `build()` against an input this map has no entry for
  // and silently discards every write as "unexpected output".
  @override
  Map<String, List<String>> get buildExtensions => {
    r'$package$': [for (final path in outputFiles.keys) _joinOutputPath(path)],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    // Warnings were collected synchronously in the builder factory (before a
    // `log` zone existed) — flush them now that we're running inside
    // build_runner's logging zone.
    for (final warning in warnings) {
      log.warning(warning);
    }
    for (final entry in outputFiles.entries) {
      final id = AssetId(buildStep.inputId.package, _joinOutputPath(entry.key));
      await buildStep.writeAsString(id, entry.value);
    }
  }

  String _joinOutputPath(String relativePath) {
    final dir =
        config.outputDir.endsWith('/')
            ? config.outputDir.substring(0, config.outputDir.length - 1)
            : config.outputDir;
    return '$dir/$relativePath';
  }
}
