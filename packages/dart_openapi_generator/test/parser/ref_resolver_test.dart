import 'package:dart_openapi_generator/src/model/openapi_parse_exception.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/parser/ref_resolver.dart';
import 'package:dart_openapi_generator/src/parser/schema_parser.dart';
import 'package:dart_openapi_generator/src/parser/source_map.dart';
import 'package:test/test.dart';

Map<String, dynamic> _makeDoc({Map<String, dynamic> schemas = const {}}) => {
  'openapi': '3.0.3',
  'components': {'schemas': schemas},
  'paths': {},
};

(SchemaParser, RefResolver) _makeParser(Map<String, dynamic> doc) {
  final sourceMap = const SourceMap.empty();
  final resolver = RefResolver(doc, sourceMap);
  final parser = SchemaParser(sourceMap, resolver);
  return (parser, resolver);
}

void main() {
  group('RefResolver', () {
    test('resolves a simple \$ref to ObjectSchema', () {
      final doc = _makeDoc(
        schemas: {
          'User': {'type': 'object', 'properties': {}},
        },
      );
      final (_, resolver) = _makeParser(doc);
      final result = resolver.resolve('#/components/schemas/User', '#');
      expect(result, isA<ObjectSchema>());
    });

    test('memoizes: resolving same ref twice returns identical object', () {
      final doc = _makeDoc(
        schemas: {
          'User': {'type': 'object', 'properties': {}},
        },
      );
      final (_, resolver) = _makeParser(doc);
      final first = resolver.resolve('#/components/schemas/User', '#');
      final second = resolver.resolve('#/components/schemas/User', '#');
      expect(identical(first, second), isTrue);
    });

    test('rejects external \$ref (PARSE-04)', () {
      final doc = _makeDoc();
      final (_, resolver) = _makeParser(doc);
      expectLater(
        () => resolver.resolve('./other.yaml#/components/schemas/User', '#'),
        throwsA(
          isA<OpenApiParseException>().having(
            (e) => e.message,
            'message',
            contains('v0.2.x'),
          ),
        ),
      );
    });

    test('cycle detection returns SchemaObject (not infinite loop)', () {
      final doc = _makeDoc(
        schemas: {
          'User': {
            'type': 'object',
            'properties': {
              'manager': {r'$ref': '#/components/schemas/User'},
            },
          },
        },
      );
      final (_, resolver) = _makeParser(doc);
      // Should complete without stack overflow
      expect(
        () => resolver.resolve('#/components/schemas/User', '#'),
        returnsNormally,
      );
    });

    test('throws for missing \$ref target', () {
      final doc = _makeDoc();
      final (_, resolver) = _makeParser(doc);
      expectLater(
        () => resolver.resolve('#/components/schemas/NonExistent', '#'),
        throwsA(isA<OpenApiParseException>()),
      );
    });
  });
}
