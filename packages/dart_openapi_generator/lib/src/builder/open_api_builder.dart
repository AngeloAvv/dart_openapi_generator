import 'dart:typed_data';

import 'package:build/build.dart';
import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';
import 'package:source_gen/source_gen.dart';

import '../cache_manager.dart';
import '../generator/aggregator_generator.dart';
import '../generator/model_generator.dart';
import '../generator/service_generator.dart';
import '../model/openapi_parse_exception.dart';
import '../writer/file_writer.dart';
import '../name_registry/name_registry.dart';
import '../parser/openapi_parser.dart';
import '../parser/spec_sniffer.dart';
import '../parser/version_validator.dart';
import '../resolved_annotation.dart';
import '../spec_loader.dart';

/// Build-time generator that discovers [@OpenApiGenerator] annotations and
/// emits model classes, service classes, and the aggregator client.
class OpenApiBuilder implements Builder {
  // Use source-file URI — NOT the barrel re-export URI.
  // Using the barrel re-export URI causes annotatedWith() to return empty.
  static final _typeChecker = TypeChecker.fromUrl(
    'package:dart_openapi_generator_annotations/src/open_api_generator.dart#OpenApiGenerator',
  );

  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.openapi_generator.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    // Guard: part files are not libraries; skip them rather than throwing.
    // NonLibraryAssetException is the signal from build 4.0.6 for part files.
    // Wrapping the full body avoids a late-final uninitialized variable.
    try {
      await _buildLibrary(buildStep);
    } on NonLibraryAssetException {
      return; // skip part files — they are not libraries
    }
  }

  Future<void> _buildLibrary(BuildStep buildStep) async {
    final library = await buildStep.inputLibrary;
    final reader = LibraryReader(library);

    final annotated = reader.annotatedWith(_typeChecker);
    if (annotated.isEmpty) return;

    // Warn about any extra annotations beyond the first — they are silently ignored.
    if (annotated.length > 1) {
      final ignored = annotated.skip(1).map((e) => e.element.name).join(', ');
      log.warning(
        'dart_openapi_generator: multiple @OpenApiGenerator annotations found '
        'in ${buildStep.inputId.path}. Only the first will be processed. '
        'Ignored elements: $ignored',
      );
    }

    // Take the first annotation.
    final element = annotated.first;
    final resolved = ResolvedAnnotation.fromConstantReader(
      element.annotation,
      element.element,
    );

    if (resolved.outputDir.isEmpty) {
      throw InvalidGenerationSource(
        'outputDir must not be empty.',
        todo:
            "Add outputDir to your @OpenApiGenerator annotation: "
            "@OpenApiGenerator(outputDir: 'lib/generated', ...)",
        element: element.element,
      );
    }

    final SpecLoader specLoader = switch (resolved.inputSpec) {
      LocalSpec() => const LocalSpecLoader(),
      RemoteSpec() => const RemoteSpecLoader(),
    };
    final Uint8List specBytes = await specLoader.load(resolved);
    final String cacheKey = CacheManager.computeCacheKey(specBytes, resolved);

    if (await const CacheManager().shouldSkip(cacheKey, resolved)) {
      log.info(
        'dart_openapi_generator: cache hit — skipping codegen for '
        '${buildStep.inputId.path}',
      );
      return;
    }

    late final ParseResult parseResult;
    try {
      final sniffResult = sniffSpec(specBytes);
      final sniffSourceMap = switch (sniffResult) {
        YamlSniffResult(:final sourceMap) => sourceMap,
        JsonSniffResult(:final sourceMap) => sourceMap,
      };
      validateVersion(sniffResult.map['openapi'] as String?, sniffSourceMap);
      parseResult = parseSpec(sniffResult.map, sniffSourceMap);
    } on OpenApiParseException catch (e) {
      throw InvalidGenerationSource(
        'dart_openapi_generator: failed to parse spec — $e',
        element: element.element,
      );
    }

    final registry = buildNameRegistry(parseResult.document);
    final modelFiles = ModelGenerator(
      registry,
      resolved.dateTimeConverter,
      onWarning: (msg) => log.warning(msg),
    ).generate(parseResult.document);

    final serviceFiles = ServiceGenerator(
      registry,
      onWarning: (msg) => log.warning(msg),
    ).generate(parseResult.document);

    final aggregatorFiles = AggregatorGenerator(
      onWarning: (msg) => log.warning(msg),
    ).generate(parseResult.document, resolved);

    final allFiles = {...modelFiles, ...serviceFiles, ...aggregatorFiles};

    await FileWriter(
      onLog: resolved.debugLogging ? (msg) => log.info(msg) : null,
    ).write(allFiles, resolved);

    // Write cache AFTER FileWriter.write() completes.
    // A FileWriter failure must not poison the cache and cause future builds
    // to be silently skipped.
    if (resolved.skipIfSpecIsUnchanged) {
      await const CacheManager().writeCache(cacheKey, resolved);
    }

    // Sentinel output: co-located with the annotated source file.
    // buildStep.writeAsString ONLY accepts paths within allowedOutputs
    // (derived from buildExtensions). Writing to outputDir uses dart:io directly.
    final outputId = buildStep.inputId.changeExtension(
      '.openapi_generator.g.dart',
    );
    await buildStep.writeAsString(outputId, _sentinelContent(resolved));

    log.info(
      'dart_openapi_generator: sentinel written for ${buildStep.inputId.path} '
      '→ outputDir=${resolved.outputDir}',
    );
  }

  static String _sentinelContent(ResolvedAnnotation r) =>
      '// GENERATED CODE - DO NOT MODIFY BY HAND\n'
      '// ignore_for_file: type=lint\n'
      '//\n'
      '// dart_openapi_generator placeholder — real output written to outputDir.\n'
      '// outputDir: ${r.outputDir}\n';
}
