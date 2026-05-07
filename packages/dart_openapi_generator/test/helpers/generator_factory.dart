import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:dart_openapi_generator/src/resolved_annotation.dart';
import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';
import 'package:source_gen/source_gen.dart';

/// Returns the test-only adapter generator used by [testAnnotatedElements].
///
/// [source_gen_test]'s [testAnnotatedElements] requires a
/// [GeneratorForAnnotation], not a [Builder]. This factory provides the
/// adapter that wraps [ResolvedAnnotation] decoding without any file I/O.
OpenApiTestGenerator createTestGenerator() => OpenApiTestGenerator();

/// Test-only adapter.
///
/// Wraps annotation decoding via [ResolvedAnnotation.fromConstantReader] and
/// returns the sentinel string. Does NOT call any [BuildStep] methods — the
/// [source_gen_test] mock throws [NoSuchMethodError] for any such call.
class OpenApiTestGenerator extends GeneratorForAnnotation<OpenApiGenerator> {
  @override
  String generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) {
    final resolved = ResolvedAnnotation.fromConstantReader(annotation, element);

    // Mirror the outputDir validation from OpenApiBuilder — outputDir must not
    // be empty. Throwing InvalidGenerationSource here satisfies @ShouldThrow in
    // golden tests without calling any BuildStep methods.
    if (resolved.outputDir.isEmpty) {
      throw InvalidGenerationSource(
        'outputDir must not be empty.',
        todo:
            'Add outputDir to your @OpenApiGenerator annotation: '
            "@OpenApiGenerator(outputDir: 'lib/generated', ...)",
        element: element,
      );
    }

    return _sentinelContent(resolved);
  }

  // Must match OpenApiBuilder._sentinelContent exactly (sans trailing newline —
  // @ShouldGenerate uses contains: true so substring match is sufficient).
  static String _sentinelContent(ResolvedAnnotation r) =>
      '// GENERATED CODE - DO NOT MODIFY BY HAND\n'
      '// ignore_for_file: type=lint\n'
      '//\n'
      '// dart_openapi_generator placeholder — real output written to outputDir.\n'
      '// outputDir: ${r.outputDir}';
}
