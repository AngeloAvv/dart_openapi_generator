import 'dart:io';
import 'dart:isolate';

import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/model/spec_document.dart';
import 'package:dart_openapi_generator/src/parser/openapi_parser.dart';
import 'package:dart_openapi_generator/src/parser/spec_sniffer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<String> _fixturesDir() async {
  final packageUri = await Isolate.resolvePackageUri(
    Uri.parse('package:dart_openapi_generator/'),
  );
  // packageUri points to lib/ inside the package root
  return p.join(packageUri!.toFilePath(), '..', 'test', 'fixtures');
}

Future<SpecDocument> _parseFile(String filename) async {
  final dir = await _fixturesDir();
  final file = File(p.join(dir, filename));
  final bytes = file.readAsBytesSync();
  final sniff = sniffSpec(bytes);
  final sourceMap = switch (sniff) {
    YamlSniffResult(:final sourceMap) => sourceMap,
    JsonSniffResult(:final sourceMap) => sourceMap,
  };
  return const OpenApiParser().parse(sniff.map, sourceMap);
}

void _testFixture(String filename, void Function(SpecDocument) verify) {
  test(filename, () async {
    final dir = await _fixturesDir();
    final file = File(p.join(dir, filename));
    expect(
      file.existsSync(),
      isTrue,
      reason: 'Fixture file must exist: $filename',
    );
    verify(await _parseFile(filename));
  });
}

void main() {
  group('Fixture integration tests (PARSE-11)', () {
    _testFixture('stripe_recursive_ref.yaml', (doc) {
      // Stripe fixture exercises PARSE-03: recursive ref must parse without error
      expect(doc.schemas, isNotEmpty);
    });

    _testFixture('github_discriminator.yaml', (doc) {
      // GitHub fixture exercises PARSE-07: discriminator validation
      expect(doc.schemas, isNotEmpty);
    });

    _testFixture('discord_enum.yaml', (doc) {
      // Discord fixture exercises PARSE-05 enum, NAME-02 case conversion
      expect(doc.schemas.values.any((s) => s is EnumSchema), isTrue);
    });

    _testFixture('petstore_nullable_30.yaml', (doc) {
      // Petstore 3.0 fixture exercises PARSE-06 nullable:true normalization
      expect(doc.schemas, isNotEmpty);
    });

    _testFixture('petstore_nullable_31.yaml', (doc) {
      // Petstore 3.1 fixture exercises PARSE-06 type:[T,null] normalization
      expect(doc.schemas, isNotEmpty);
    });

    _testFixture('openapi_32_features.yaml', (doc) {
      // 3.2 fixture includes a non-standard verb under a path item (PARSE-08).
      // Verify additionalMethods is populated on at least one operation.
      expect(
        doc.operations.any((op) => op.additionalMethods.isNotEmpty),
        isTrue,
      );
    });
  });
}
