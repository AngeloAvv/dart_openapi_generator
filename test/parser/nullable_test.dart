import 'package:dart_openapi_generator/src/model/openapi_parse_exception.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/parser/ref_resolver.dart';
import 'package:dart_openapi_generator/src/parser/schema_parser.dart';
import 'package:dart_openapi_generator/src/parser/source_map.dart';
import 'package:test/test.dart';

SchemaParser _makeParser() {
  final sm = const SourceMap.empty();
  return SchemaParser(sm, RefResolver({}, sm));
}

void main() {
  group('Nullable normalization (PARSE-06)', () {
    test('3.0 nullable:true → isNullable=true', () {
      final r = _makeParser().parse({'type': 'string', 'nullable': true}, '#');
      expect(r.isNullable, isTrue);
    });
    test('3.1 type:[string,null] → isNullable=true, primitiveType=string', () {
      final r = _makeParser().parse({
        'type': ['string', 'null'],
      }, '#');
      expect(r.isNullable, isTrue);
      expect(r, isA<PrimitiveSchema>());
      expect((r as PrimitiveSchema).primitiveType, equals('string'));
    });
    test('no nullable → isNullable=false', () {
      final r = _makeParser().parse({'type': 'string'}, '#');
      expect(r.isNullable, isFalse);
    });
    test(
      'mixed style (nullable:true AND type:[T,null]) → throws (PARSE-06)',
      () {
        expectLater(
          () => _makeParser().parse({
            'type': ['string', 'null'],
            'nullable': true,
          }, '#'),
          throwsA(
            isA<OpenApiParseException>().having(
              (e) => e.message,
              'message',
              contains('Mixed nullable'),
            ),
          ),
        );
      },
    );
  });
}
