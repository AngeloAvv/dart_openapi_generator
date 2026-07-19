import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_openapi_generator/src/model/openapi_parse_exception.dart';
import 'package:dart_openapi_generator/src/parser/spec_sniffer.dart';
import 'package:test/test.dart';

Uint8List _yamlBytes([
  String yaml =
      'openapi: "3.0.3"\ninfo:\n  title: T\n  version: v1\npaths: {}\n',
]) => Uint8List.fromList(utf8.encode(yaml));

Uint8List _jsonBytes([
  Map<String, dynamic> map = const {
    'openapi': '3.0.3',
    'info': {'title': 'T', 'version': 'v1'},
    'paths': {},
  },
]) => Uint8List.fromList(utf8.encode(jsonEncode(map)));

void main() {
  group('sniffSpec', () {
    test('returns YamlSniffResult for YAML bytes', () {
      final result = sniffSpec(_yamlBytes());
      expect(result, isA<YamlSniffResult>());
    });
    test('returns JsonSniffResult for JSON bytes starting with {', () {
      final result = sniffSpec(_jsonBytes());
      expect(result, isA<JsonSniffResult>());
    });
    test('YAML result carries non-empty sourceMap for spec with content', () {
      final result = sniffSpec(_yamlBytes()) as YamlSniffResult;
      expect(result.sourceMap.spanAt('#'), isNotNull);
    });
    test('JSON result has empty sourceMap', () {
      final result = sniffSpec(_jsonBytes()) as JsonSniffResult;
      expect(result.sourceMap.spanAt('#'), isNull);
    });
    test('YAML result map has openapi key', () {
      final result = sniffSpec(_yamlBytes());
      expect(result.map['openapi'], equals('3.0.3'));
    });
    test('throws for empty bytes', () {
      expectLater(
        () => sniffSpec(Uint8List(0)),
        throwsA(isA<OpenApiParseException>()),
      );
    });
    test('YAML with leading whitespace is still parsed as YAML', () {
      final result = sniffSpec(
        _yamlBytes(
          '  \nopenapi: "3.0.3"\ninfo:\n  title: T\n  version: v1\npaths: {}\n',
        ),
      );
      expect(result, isA<YamlSniffResult>());
    });
  });
}
