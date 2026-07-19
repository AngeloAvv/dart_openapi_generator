import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_openapi_generator/src/model/openapi_parse_exception.dart';
import 'package:dart_openapi_generator/src/parser/openapi_parser.dart';
import 'package:dart_openapi_generator/src/parser/spec_sniffer.dart';
import 'package:dart_openapi_generator/src/parser/source_map.dart';
import 'package:dart_openapi_generator/src/parser/version_validator.dart';
import 'package:test/test.dart';

Uint8List _bytes(String yaml) => Uint8List.fromList(utf8.encode(yaml));

SourceMap _sniffSourceMap(SniffResult sniff) => switch (sniff) {
  YamlSniffResult(:final sourceMap) => sourceMap,
  JsonSniffResult(:final sourceMap) => sourceMap,
};

void main() {
  group('Error context (PARSE-09)', () {
    test('version error includes #/openapi json pointer', () {
      const yaml =
          'openapi: "2.0.0"\ninfo:\n  title: T\n  version: v1\npaths: {}\n';
      final sniff = sniffSpec(_bytes(yaml));
      final sourceMap = _sniffSourceMap(sniff);
      expectLater(
        () => validateVersion(sniff.map['openapi'] as String?, sourceMap),
        throwsA(
          isA<OpenApiParseException>().having(
            (e) => e.jsonPointer,
            'jsonPointer',
            equals('#/openapi'),
          ),
        ),
      );
    });

    test('YAML version error includes line/col in toString()', () {
      const yaml =
          'openapi: "2.0.0"\ninfo:\n  title: T\n  version: v1\npaths: {}\n';
      final sniff = sniffSpec(_bytes(yaml)) as YamlSniffResult;
      try {
        validateVersion(sniff.map['openapi'] as String?, sniff.sourceMap);
        fail('Expected OpenApiParseException');
      } on OpenApiParseException catch (e) {
        // toString includes 'line N, col N' for YAML input
        expect(e.toString(), contains('line'));
      }
    });

    test('toString format: OpenAPI parse error at <pointer> ...: <msg>', () {
      const ex = OpenApiParseException('test message', jsonPointer: '#/test');
      expect(ex.toString(), contains('OpenAPI parse error at #/test'));
      expect(ex.toString(), contains('test message'));
    });

    test('JSON input exception has no line/col (span is null)', () {
      const ex = OpenApiParseException('msg', jsonPointer: '#/test');
      // No sourceSpan → toString omits "(line N, col N)"
      expect(ex.toString(), isNot(contains('line')));
    });

    test('parse of a valid 3.0.3 spec returns a SpecDocument', () {
      const yaml = '''
openapi: "3.0.3"
info:
  title: Test
  version: v1
paths: {}
''';
      final sniff = sniffSpec(_bytes(yaml));
      final sm = _sniffSourceMap(sniff);
      final doc = const OpenApiParser().parse(sniff.map, sm);
      expect(doc.title, equals('Test'));
      expect(doc.specVersion, equals('3.0.3'));
    });
  });
}
