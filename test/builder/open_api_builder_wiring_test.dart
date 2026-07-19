import 'dart:io';

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:dart_openapi_generator/builder.dart';
import 'package:dart_openapi_generator/src/date_time_converter.dart';
import 'package:dart_openapi_generator/src/generator/aggregator_generator.dart';
import 'package:dart_openapi_generator/src/generator/model_generator.dart';
import 'package:dart_openapi_generator/src/generator_config.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/model/spec_document.dart';
import 'package:dart_openapi_generator/src/name_registry/name_registry.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

GeneratorConfig _makeConfig({String clientName = 'ApiClient'}) =>
    GeneratorConfig(
      inputSpec: 'openapi.yaml',
      outputDir: 'lib/generated',
      clientName: clientName,
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

const _minimalSpec = '''
openapi: "3.0.3"
info:
  title: "Test API"
  version: "1.0.0"
paths:
  /users:
    get:
      operationId: listUsers
      tags: [Users]
      responses:
        "200":
          description: ok
          content:
            application/json:
              schema:
                \$ref: '#/components/schemas/User'
components:
  schemas:
    User:
      type: object
      required: [id]
      properties:
        id:
          type: string
''';

/// Trivial downstream builder — stands in for a consumer's own
/// source_gen-style builder (e.g. `dart_mapper_generator`) that imports a
/// dart_openapi_generator-generated type.
class _DownstreamBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => {
    '.dart': ['.downstream.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    if (!buildStep.inputId.path.endsWith('consumer.dart')) return;
    await buildStep.inputLibrary; // proves consumer.dart itself resolves
    final LibraryElement userLib = await buildStep.resolver.libraryFor(
      AssetId(buildStep.inputId.package, 'lib/generated/models/user.dart'),
    );
    final resolved = userLib.classes.any((c) => c.name == 'User');
    final outputId = buildStep.inputId.changeExtension('.downstream.g.dart');
    await buildStep.writeAsString(outputId, '// resolved User: $resolved\n');
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // Single-pass regression test — this is the fix for the bug documented in
  // HANDOVER-single-pass-build.md: OpenApiBuilder used to write real output
  // via dart:io, invisible to build_runner's asset graph, so a downstream
  // builder in the same invocation could never resolve generated types on
  // the first pass. Now the builder factory computes buildExtensions
  // synchronously and build() writes via buildStep.writeAsString, so both
  // builders run in a single simulated build here.
  // -------------------------------------------------------------------------
  group('single-pass resolution (regression)', () {
    test('downstream builder resolves a dart_openapi_generator-generated type '
        'in the same build pass', () async {
      final tmpDir = await Directory.systemTemp.createTemp(
        'open_api_builder_wiring_test_',
      );
      addTearDown(() => tmpDir.delete(recursive: true));
      final specFile = File('${tmpDir.path}/openapi.yaml');
      await specFile.writeAsString(_minimalSpec);

      // Factory runs synchronously here, exactly as build_runner would at
      // the start of a real `build_runner build` invocation — this is the
      // real production code path, not a reimplementation.
      final openApiBuilder = dartOpenApiBuilder(
        BuilderOptions({
          'input_spec': specFile.path,
          'output_dir': 'lib/generated',
          'client_name': 'TestApiClient',
        }),
      );

      await testBuilders(
        [openApiBuilder, _DownstreamBuilder()],
        {
          'pkg|lib/consumer.dart': '''
import 'generated/models/user.dart';
void main() {}
''',
        },
        // Exhaustive: testBuilders fails on any unlisted output, so every
        // file the (real) OpenApiBuilder + AggregatorGenerator produce for
        // this minimal spec must be accounted for — the two entries that
        // actually matter for this regression are models/user.dart and
        // the downstream builder's resolution proof.
        outputs: {
          'pkg|lib/generated/models/user.dart': decodedMatches(
            contains('class User'),
          ),
          'pkg|lib/generated/api_client.dart': anything,
          'pkg|lib/generated/generated.dart': anything,
          'pkg|lib/generated/services/users_api.dart': anything,
          'pkg|lib/consumer.downstream.g.dart': decodedMatches(
            '// resolved User: true\n',
          ),
        },
      );
    });
  });

  // -------------------------------------------------------------------------
  // Output layout: subdirectory paths
  // -------------------------------------------------------------------------
  group('output layout — subdirectory paths', () {
    test('AggregatorGenerator import paths use services/ subdirectory', () {
      final doc = _makeDocWithOp('users');
      final config = _makeConfig();
      final result = const AggregatorGenerator().generate(doc, config);
      final source = result['api_client.dart']!;

      expect(
        source,
        contains("import 'services/users_api.dart';"),
        reason: 'AggregatorGenerator must import from services/ subdirectory.',
      );
    });

    test('ModelGenerator output keys use models/ subdirectory', () {
      // ModelGenerator map keys must use models/ prefix,
      // confirming the builder will write models to the models/ subdir.
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
            'the builder will write models to {outputDir}/models/.',
      );
    });
  });
}
