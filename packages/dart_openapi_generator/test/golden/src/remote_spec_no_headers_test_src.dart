import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';
import 'package:source_gen_test/annotations.dart';

@ShouldGenerate(
  '// GENERATED CODE - DO NOT MODIFY BY HAND\n'
  '// ignore_for_file: type=lint\n'
  '//\n'
  '// dart_openapi_generator placeholder — real output written to outputDir.\n'
  '// outputDir: lib/generated',
  contains: true,
)
@OpenApiGenerator(
  inputSpec: RemoteSpec('https://petstore3.swagger.io/api/v3/openapi.json'),
  outputDir: 'lib/generated',
)
class $TestApp {}
