import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_openapi_generator/src/parser/openapi_parser.dart';
import 'package:dart_openapi_generator/src/parser/spec_sniffer.dart';
import 'package:dart_openapi_generator/src/model/spec_document.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<String> _fixturesDir() async {
  final packageUri = await Isolate.resolvePackageUri(
    Uri.parse('package:dart_openapi_generator/'),
  );
  // packageUri points to lib/ inside the package root
  return p.join(packageUri!.toFilePath(), '..', 'test', 'fixtures');
}

SpecDocument _parseYaml(String yaml) {
  final bytes = Uint8List.fromList(utf8.encode(yaml));
  final sniff = sniffSpec(bytes);
  final sourceMap = switch (sniff) {
    YamlSniffResult(:final sourceMap) => sourceMap,
    JsonSniffResult(:final sourceMap) => sourceMap,
  };
  return const OpenApiParser().parse(sniff.map, sourceMap);
}

void main() {
  group('OpenAPI 3.2 features (PARSE-08)', () {
    test('in:querystring parameter parsed and stored correctly', () {
      const yaml = '''
openapi: "3.2.0"
info:
  title: Test
  version: v1
paths:
  /search:
    get:
      operationId: search
      parameters:
        - name: q
          in: querystring
          required: false
          schema:
            type: string
      responses:
        "200":
          description: OK
''';
      final doc = _parseYaml(yaml);
      final op = doc.operations.first;
      expect(op.parameters.first.location, equals('querystring'));
    });

    test('additionalMethods stored on 3.2 spec (from fixture)', () async {
      final dir = await _fixturesDir();
      final fixtureFile = File(p.join(dir, 'openapi_32_features.yaml'));
      final bytes = fixtureFile.readAsBytesSync();
      final sniff = sniffSpec(bytes);
      final sourceMap = switch (sniff) {
        YamlSniffResult(:final sourceMap) => sourceMap,
        JsonSniffResult(:final sourceMap) => sourceMap,
      };
      final doc = const OpenApiParser().parse(sniff.map, sourceMap);
      // The fixture includes a non-standard verb (query:) under a path item;
      // verify it is captured in additionalMethods (PARSE-08).
      expect(
        doc.operations.any((op) => op.additionalMethods.isNotEmpty),
        isTrue,
      );
    });
  });
}
