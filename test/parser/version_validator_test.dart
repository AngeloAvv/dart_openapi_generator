import 'package:dart_openapi_generator/src/model/openapi_parse_exception.dart';
import 'package:dart_openapi_generator/src/parser/source_map.dart';
import 'package:dart_openapi_generator/src/parser/version_validator.dart';
import 'package:test/test.dart';

void main() {
  group('validateVersion', () {
    test('accepts 3.0.3', () {
      expect(
        () => validateVersion('3.0.3', const SourceMap.empty()),
        returnsNormally,
      );
    });
    test('accepts 3.1.0', () {
      expect(
        () => validateVersion('3.1.0', const SourceMap.empty()),
        returnsNormally,
      );
    });
    test('accepts 3.2.0', () {
      expect(
        () => validateVersion('3.2.0', const SourceMap.empty()),
        returnsNormally,
      );
    });
    test('rejects 2.0.0 (Swagger)', () {
      expectLater(
        () => validateVersion('2.0.0', const SourceMap.empty()),
        throwsA(
          isA<OpenApiParseException>().having(
            (e) => e.jsonPointer,
            'jsonPointer',
            equals('#/openapi'),
          ),
        ),
      );
    });
    test('rejects null (missing field)', () {
      expectLater(
        () => validateVersion(null, const SourceMap.empty()),
        throwsA(isA<OpenApiParseException>()),
      );
    });
    test('rejects unknown major 4.0.0', () {
      expectLater(
        () => validateVersion('4.0.0', const SourceMap.empty()),
        throwsA(
          isA<OpenApiParseException>().having(
            (e) => e.message,
            'message',
            contains('4'),
          ),
        ),
      );
    });
    test('error message for 2.x contains actionable suggestion', () {
      expectLater(
        () => validateVersion('2.0.0', const SourceMap.empty()),
        throwsA(
          isA<OpenApiParseException>().having(
            (e) => e.message,
            'message',
            contains('Convert'),
          ),
        ),
      );
    });
  });
}
