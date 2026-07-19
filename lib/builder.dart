import 'package:build/build.dart';

import 'src/builder/open_api_builder.dart';
import 'src/generator_config.dart';

/// Factory function wired into build.yaml under `builder_factories`.
///
/// Runs synchronously (`Builder Function(BuilderOptions)`, not a `Future`),
/// which is exactly what lets it read [options.config] (the consumer's
/// `build.yaml` `options:` block) and run the whole OpenAPI codegen
/// pipeline — spec read, parse, generate, format — *before* returning the
/// [OpenApiBuilder] instance. That's how [OpenApiBuilder.buildExtensions]
/// can declare the real, project-specific list of output files up front, so
/// build_runner tracks them in its asset graph instead of them being written
/// out-of-band via `dart:io`.
Builder dartOpenApiBuilder(BuilderOptions options) {
  final config = GeneratorConfig.fromBuilderOptions(options);
  final result = OpenApiBuilder.generateFiles(config);
  return OpenApiBuilder(config, result.files, result.warnings);
}
