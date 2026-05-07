import 'dart:io';

import 'package:dart_openapi_generator/src/generator/aggregator_generator.dart';
import 'package:dart_openapi_generator/src/generator/model_generator.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/model/spec_document.dart';
import 'package:dart_openapi_generator/src/name_registry/name_registry.dart';
import 'package:dart_openapi_generator/src/resolved_annotation.dart';
import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ResolvedAnnotation _makeAnnotation({String clientName = 'ApiClient'}) =>
    ResolvedAnnotation(
      inputSpec: const LocalSpec('openapi.yaml'),
      outputDir: 'lib/generated',
      clientName: clientName,
      skipIfSpecIsUnchanged: true,
      cachePath: '.dart_tool/dart_openapi_generator_cache',
      cleanOutput: false,
      dateTimeConverter: DateTimeConverter.iso8601,
      debugLogging: false,
    );

SpecDocument _makeDocWithOp(String tag) => SpecDocument(
  specVersion: '3.0.3',
  title: 'Test',
  baseUrl: 'https://api.example.com',
  schemas: const {},
  operations: [
    OperationItem(
      path: '/test',
      method: 'get',
      tags: [tag],
      parameters: const [],
      responses: const {},
      security: const [],
      additionalMethods: const [],
    ),
  ],
  securitySchemes: const {},
);

SpecDocument _makeDocWithSchema(String schemaName) => SpecDocument(
  specVersion: '3.0.3',
  title: 'Test',
  baseUrl: 'https://api.example.com',
  schemas: {
    schemaName: const ObjectSchema(
      properties: [
        SchemaProperty(
          specName: 'id',
          schema: PrimitiveSchema(primitiveType: 'string'),
          isRequired: true,
        ),
      ],
      required: ['id'],
    ),
  },
  operations: const [],
  securitySchemes: const {},
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // Sentinel regression guard
  // -------------------------------------------------------------------------
  group('sentinel regression guard', () {
    test('open_api_builder.dart still contains writeAsString call', () {
      final source =
          File('lib/src/builder/open_api_builder.dart').readAsStringSync();
      expect(
        source,
        contains('writeAsString'),
        reason: 'Sentinel output must call buildStep.writeAsString.',
      );
    });

    test('open_api_builder.dart still contains _sentinelContent reference', () {
      final source =
          File('lib/src/builder/open_api_builder.dart').readAsStringSync();
      expect(
        source,
        contains('_sentinelContent'),
        reason: '_sentinelContent must remain in open_api_builder.dart.',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Output layout: subdirectory paths
  // -------------------------------------------------------------------------
  group('output layout — subdirectory paths', () {
    test('AggregatorGenerator import paths use services/ subdirectory', () {
      final doc = _makeDocWithOp('users');
      final annotation = _makeAnnotation();
      final result = const AggregatorGenerator().generate(doc, annotation);
      final source = result['api_client.dart']!;

      expect(
        source,
        contains("import 'services/users_api.dart';"),
        reason: 'AggregatorGenerator must import from services/ subdirectory.',
      );
    });

    test('ModelGenerator output keys use models/ subdirectory', () {
      // ModelGenerator map keys must use models/ prefix,
      // confirming FileWriter will write models to the models/ subdir.
      final doc = _makeDocWithSchema('User');
      final registry = buildNameRegistry(doc);
      final result = ModelGenerator(
        registry,
        DateTimeConverter.iso8601,
      ).generate(doc);

      expect(
        result.keys,
        anyElement(startsWith('models/')),
        reason:
            'ModelGenerator must produce keys under models/ subdirectory — '
            'FileWriter will write models to {outputDir}/models/.',
      );
    });
  });
}
