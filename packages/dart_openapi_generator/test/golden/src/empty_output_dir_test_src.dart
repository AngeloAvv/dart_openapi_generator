import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';
import 'package:source_gen_test/annotations.dart';

@ShouldThrow('outputDir must not be empty.', element: '\$EmptyOutputDir')
@OpenApiGenerator(inputSpec: LocalSpec('openapi/api.yaml'), outputDir: '')
class $EmptyOutputDir {}
