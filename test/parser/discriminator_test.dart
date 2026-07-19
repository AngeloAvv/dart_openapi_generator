import 'package:dart_openapi_generator/src/model/openapi_parse_exception.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/parser/ref_resolver.dart';
import 'package:dart_openapi_generator/src/parser/schema_parser.dart';
import 'package:dart_openapi_generator/src/parser/source_map.dart';
import 'package:test/test.dart';

SchemaParser _makeParser([Map<String, dynamic> doc = const {}]) {
  final sm = const SourceMap.empty();
  return SchemaParser(sm, RefResolver(doc, sm));
}

void main() {
  group('Discriminator validation (PARSE-07)', () {
    test(
      'oneOf with discriminator, all variants have property → OneOfSchema',
      () {
        final r = _makeParser().parse({
          'oneOf': [
            {
              'type': 'object',
              'properties': {
                'kind': {'type': 'string'},
                'name': {'type': 'string'},
              },
            },
            {
              'type': 'object',
              'properties': {
                'kind': {'type': 'string'},
                'age': {'type': 'integer'},
              },
            },
          ],
          'discriminator': {'propertyName': 'kind'},
        }, '#');
        expect(r, isA<OneOfSchema>());
        expect((r as OneOfSchema).discriminatorPropertyName, equals('kind'));
      },
    );

    test(
      'oneOf with discriminator, variant missing property → throws (PARSE-07)',
      () {
        expectLater(
          () => _makeParser().parse({
            'oneOf': [
              {
                'type': 'object',
                'properties': {
                  'kind': {'type': 'string'},
                },
              },
              {
                'type': 'object',
                'properties': {
                  'name': {'type': 'string'},
                }, // missing 'kind'
              },
            ],
            'discriminator': {'propertyName': 'kind'},
          }, '#'),
          throwsA(
            isA<OpenApiParseException>().having(
              (e) => e.message,
              'message',
              contains('discriminator property'),
            ),
          ),
        );
      },
    );

    test('oneOf without discriminator is valid', () {
      final r = _makeParser().parse({
        'oneOf': [
          {'type': 'string'},
          {'type': 'integer'},
        ],
      }, '#');
      expect(r, isA<OneOfSchema>());
      expect((r as OneOfSchema).discriminatorPropertyName, isNull);
    });
  });
}
