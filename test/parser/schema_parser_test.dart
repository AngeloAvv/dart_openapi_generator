import 'package:dart_openapi_generator/src/model/openapi_parse_exception.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/parser/ref_resolver.dart';
import 'package:dart_openapi_generator/src/parser/schema_parser.dart';
import 'package:dart_openapi_generator/src/parser/source_map.dart';
import 'package:test/test.dart';

SchemaParser _makeParser([Map<String, dynamic> doc = const {}]) {
  final sourceMap = const SourceMap.empty();
  final resolver = RefResolver(doc, sourceMap);
  return SchemaParser(sourceMap, resolver);
}

void main() {
  group('SchemaParser', () {
    group('ObjectSchema (PARSE-05)', () {
      test('type: object → ObjectSchema', () {
        final result = _makeParser().parse({
          'type': 'object',
          'properties': {},
        }, '#');
        expect(result, isA<ObjectSchema>());
      });
      test('properties without type → ObjectSchema (Pitfall 6)', () {
        final result = _makeParser().parse({
          'properties': {
            'id': {'type': 'string'},
          },
        }, '#');
        expect(result, isA<ObjectSchema>());
      });
      test('empty map (no type, no properties) → ObjectSchema', () {
        final result = _makeParser().parse({}, '#');
        expect(result, isA<ObjectSchema>());
      });
    });

    group('OneOfSchema', () {
      test('multi-branch oneOf → OneOfSchema', () {
        final result = _makeParser().parse({
          'oneOf': [
            {'type': 'string'},
            {'type': 'integer'},
          ],
        }, '#');
        expect(result, isA<OneOfSchema>());
      });

      test('single-branch inline oneOf collapses to the branch', () {
        // A path parameter declared as oneOf: [{type: string}] is a String —
        // wrapping it in a sealed class with one case helps nobody.
        final result = _makeParser().parse({
          'oneOf': [
            {'type': 'string'},
          ],
        }, '#');
        expect(result, isA<PrimitiveSchema>());
        expect((result as PrimitiveSchema).primitiveType, 'string');
      });

      test(
        'collapsed single-branch oneOf yields the branch, not a wrapper',
        () {
          // The branch keeps its own shape and metadata; nothing is re-wrapped.
          final result = _makeParser().parse({
            'oneOf': [
              {
                'type': 'array',
                'items': {'type': 'integer'},
                'description': 'the branch description',
              },
            ],
          }, '#');
          expect(result, isNot(isA<OneOfSchema>()));
          expect(result, isA<ArraySchema>());
          expect((result as ArraySchema).items, isA<PrimitiveSchema>());
          expect(result.description, 'the branch description');
        },
      );

      test('collapse carries the wrapper description onto a bare branch', () {
        final result = _makeParser().parse({
          'description': 'the wrapper description',
          'oneOf': [
            {'type': 'string', 'format': 'uuid'},
          ],
        }, '#');
        expect(result, isA<PrimitiveSchema>());
        final s = result as PrimitiveSchema;
        expect(s.description, 'the wrapper description');
        // Rebuilding the branch must not drop its other fields.
        expect(s.primitiveType, 'string');
        expect(s.format, 'uuid');
      });

      test('collapse keeps the branch description when it has one', () {
        final result = _makeParser().parse({
          'description': 'the wrapper description',
          'oneOf': [
            {'type': 'string', 'description': 'the branch description'},
          ],
        }, '#');
        expect(
          (result as PrimitiveSchema).description,
          'the branch description',
        );
      });

      test('collapse carries the wrapper description onto a nested oneOf', () {
        // The only branch is itself an inline union: collapsing must keep its
        // variants and hand it the wrapper description.
        final result = _makeParser().parse({
          'description': 'the wrapper description',
          'oneOf': [
            {
              'oneOf': [
                {'type': 'string'},
                {'type': 'integer'},
              ],
            },
          ],
        }, '#');
        expect(result, isA<OneOfSchema>());
        final union = result as OneOfSchema;
        expect(union.description, 'the wrapper description');
        expect(union.variants, hasLength(2));
        expect(
          union.variants.map((v) => (v as PrimitiveSchema).primitiveType),
          ['string', 'integer'],
        );
      });

      test(r'collapse does not overwrite the description of a $ref branch', () {
        final result = _makeParser({
          'components': {
            'schemas': {
              'Bar': {
                'type': 'object',
                'properties': <String, dynamic>{},
                'description': 'the component description',
              },
            },
          },
        }).parse({
          'description': 'the wrapper description',
          'oneOf': [
            {r'$ref': '#/components/schemas/Bar'},
          ],
        }, '#');
        expect(result, isA<ObjectSchema>());
        expect(result.name, 'Bar');
        expect(result.description, 'the component description');
      });

      test('single-branch named oneOf is preserved', () {
        // Collapsing '#/components/schemas/Foo: {oneOf: [Bar]}' would make the
        // Foo component disappear from the generated API.
        final result = _makeParser().parseWithName(
          {
            'oneOf': [
              {'type': 'object', 'properties': <String, dynamic>{}},
            ],
          },
          '#',
          'Foo',
        );
        expect(result, isA<OneOfSchema>());
        expect(result.name, 'Foo');
      });

      test('single-branch oneOf with a discriminator is preserved', () {
        final result = _makeParser().parse({
          'oneOf': [
            {
              'type': 'object',
              'properties': {
                'kind': {'type': 'string'},
              },
            },
          ],
          'discriminator': {'propertyName': 'kind'},
        }, '#');
        expect(result, isA<OneOfSchema>());
      });
    });

    group('EnumSchema (PARSE-05)', () {
      test('enum key → EnumSchema', () {
        final result = _makeParser().parse({
          'type': 'string',
          'enum': ['ACTIVE', 'INACTIVE'],
        }, '#');
        expect(result, isA<EnumSchema>());
        expect((result as EnumSchema).values, equals(['ACTIVE', 'INACTIVE']));
      });
    });

    group('PrimitiveSchema (PARSE-05)', () {
      test('type: string → PrimitiveSchema', () {
        final r = _makeParser().parse({'type': 'string'}, '#');
        expect(r, isA<PrimitiveSchema>());
        expect((r as PrimitiveSchema).primitiveType, equals('string'));
      });
      test('type: integer with format → PrimitiveSchema with format', () {
        final r = _makeParser().parse({
          'type': 'integer',
          'format': 'int64',
        }, '#');
        expect((r as PrimitiveSchema).format, equals('int64'));
      });
    });

    group('ArraySchema (PARSE-05)', () {
      test('type: array → ArraySchema', () {
        final r = _makeParser().parse({
          'type': 'array',
          'items': {'type': 'string'},
        }, '#');
        expect(r, isA<ArraySchema>());
        expect((r as ArraySchema).items, isA<PrimitiveSchema>());
      });
    });

    group('NullSchema (PARSE-05)', () {
      test('type: null → NullSchema', () {
        final r = _makeParser().parse({'type': 'null'}, '#');
        expect(r, isA<NullSchema>());
      });
    });

    group('anyOf rejection', () {
      test('anyOf present → throws with v0.2.x mention', () {
        expectLater(
          () => _makeParser().parse({'anyOf': []}, '#'),
          throwsA(
            isA<OpenApiParseException>().having(
              (e) => e.message,
              'message',
              contains('v0.2.x'),
            ),
          ),
        );
      });
    });

    group('Digit-leading schema name (PARSE-10)', () {
      test('name starting with digit → throws with rename suggestion', () {
        expectLater(
          () => _makeParser().parse(
            {'type': 'object', 'properties': {}},
            '#',
            name: '2FactorAuth',
          ),
          throwsA(
            isA<OpenApiParseException>().having(
              (e) => e.message,
              'message',
              contains('digit'),
            ),
          ),
        );
      });
    });

    group('additionalProperties', () {
      test('additionalProperties: true → bool true on ObjectSchema', () {
        final r = _makeParser().parse({
          'type': 'object',
          'properties': {},
          'additionalProperties': true,
        }, '#');
        expect((r as ObjectSchema).additionalProperties, isTrue);
      });
      test('additionalProperties: false → bool false', () {
        final r = _makeParser().parse({
          'type': 'object',
          'properties': {},
          'additionalProperties': false,
        }, '#');
        expect((r as ObjectSchema).additionalProperties, isFalse);
      });
      test('additionalProperties as schema → SchemaObject', () {
        final r = _makeParser().parse({
          'type': 'object',
          'properties': {},
          'additionalProperties': {'type': 'string'},
        }, '#');
        expect(
          (r as ObjectSchema).additionalProperties,
          isA<PrimitiveSchema>(),
        );
      });
    });

    group('allOf single-ref nullable wrapper (PARSE-06)', () {
      final doc = {
        'components': {
          'schemas': {
            'StopJTO': {'type': 'object', 'properties': {}},
          },
        },
      };

      test(
        r'single $ref + nullable:true → AllOfSchema with resolved name and isNullable',
        () {
          final result = _makeParser(doc).parse({
            'type': 'object',
            'allOf': [
              {r'$ref': '#/components/schemas/StopJTO'},
            ],
            'nullable': true,
          }, '#/components/schemas/Stop');
          expect(result, isA<AllOfSchema>());
          final s = result as AllOfSchema;
          expect(s.name, equals('StopJTO'));
          expect(s.isNullable, isTrue);
        },
      );

      test(
        r'single $ref, no nullable → AllOfSchema with resolved name, isNullable=false',
        () {
          final result = _makeParser(doc).parse({
            'type': 'object',
            'allOf': [
              {r'$ref': '#/components/schemas/StopJTO'},
            ],
          }, '#/components/schemas/Stop');
          expect(result, isA<AllOfSchema>());
          final s = result as AllOfSchema;
          expect(s.name, equals('StopJTO'));
          expect(s.isNullable, isFalse);
        },
      );

      test(
        r'two $refs → AllOfSchema with outer name only (multi-ref unchanged)',
        () {
          final doc2 = {
            'components': {
              'schemas': {
                'A': {'type': 'object', 'properties': {}},
                'B': {'type': 'object', 'properties': {}},
              },
            },
          };
          final result = _makeParser(doc2).parse(
            {
              'allOf': [
                {r'$ref': '#/components/schemas/A'},
                {r'$ref': '#/components/schemas/B'},
              ],
            },
            '#',
            name: 'Combined',
          );
          expect(result, isA<AllOfSchema>());
          expect((result as AllOfSchema).name, equals('Combined'));
        },
      );
    });
  });
}
