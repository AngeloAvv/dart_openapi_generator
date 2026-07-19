import 'package:dart_openapi_generator/src/date_time_converter.dart';
import 'package:dart_openapi_generator/src/generator/aggregator_generator.dart';
import 'package:dart_openapi_generator/src/generator_config.dart';
import 'package:dart_openapi_generator/src/model/spec_document.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

SpecDocument _makeDoc({
  String baseUrl = 'https://api.example.com',
  List<OperationItem> operations = const [],
  Map<String, SecurityScheme> securitySchemes = const {},
}) => SpecDocument(
  specVersion: '3.0.3',
  title: 'Test',
  baseUrl: baseUrl,
  schemas: const {},
  operations: operations,
  securitySchemes: securitySchemes,
);

GeneratorConfig _makeConfig({
  String clientName = 'ApiClient',
  String outputDir = 'lib/generated',
}) => GeneratorConfig(
  inputSpec: 'openapi.yaml',
  outputDir: outputDir,
  clientName: clientName,
  dateTimeConverter: DateTimeConverter.iso8601,
  debugLogging: false,
);

OperationItem _op(String tag, {String path = '/test', String method = 'get'}) =>
    OperationItem(
      path: path,
      method: method,
      tags: [tag],
      parameters: const [],
      responses: const {},
      security: const [],
      additionalMethods: const [],
    );

/// Calls AggregatorGenerator.generate() and returns the api_client.dart source.
String _generate(SpecDocument doc, {String clientName = 'ApiClient'}) {
  final config = _makeConfig(clientName: clientName);
  final generator = const AggregatorGenerator();
  final result = generator.generate(doc, config);
  return result['api_client.dart'] ??
      (throw StateError('api_client.dart not found. Got: ${result.keys}'));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // Class name
  // -------------------------------------------------------------------------
  group('class name', () {
    test(
      'generate() output contains "class ApiClient" for default clientName',
      () {
        final source = _generate(_makeDoc());
        expect(source, contains('class ApiClient'));
      },
    );

    test(
      'generate() output contains "class PetClient" for clientName PetClient',
      () {
        final source = _generate(_makeDoc(), clientName: 'PetClient');
        expect(source, contains('class PetClient'));
      },
    );
  });

  // -------------------------------------------------------------------------
  // Service fields
  // -------------------------------------------------------------------------
  group('service fields', () {
    test(
      'operations with two distinct tags produce two late final service fields',
      () {
        final doc = _makeDoc(
          operations: [
            _op('users', path: '/users'),
            _op('products', path: '/products'),
          ],
        );
        final source = _generate(doc);
        expect(source, contains('late final UsersApi users = UsersApi(_dio)'));
        expect(
          source,
          contains('late final ProductsApi products = ProductsApi(_dio)'),
        );
      },
    );

    test('service fields are emitted in alphabetical order', () {
      final doc = _makeDoc(
        operations: [
          _op('users', path: '/users'),
          _op('accounts', path: '/accounts'),
        ],
      );
      final source = _generate(doc);
      final accountsIdx = source.indexOf('late final AccountsApi');
      final usersIdx = source.indexOf('late final UsersApi');
      expect(
        accountsIdx,
        lessThan(usersIdx),
        reason: '"accounts" field should appear before "users" field',
      );
    });

    test('reserved-word tag "class" gets trailing underscore escape', () {
      final doc = _makeDoc(operations: [_op('class')]);
      final source = _generate(doc);
      // The field name for 'class' must be escaped to 'class_'
      expect(source, contains('class_'));
    });

    test('untagged operation produces "Default" tag', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/test',
            method: 'get',
            tags: [],
            parameters: [],
            responses: {},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final source = _generate(doc);
      expect(source, contains('DefaultApi'));
    });
  });

  // -------------------------------------------------------------------------
  // Constructor signature
  // -------------------------------------------------------------------------
  group('constructor signature', () {
    test('constructor contains all required parameter types', () {
      final source = _generate(_makeDoc());
      expect(source, contains('ApiClient({'));
      expect(source, contains('Dio? dio'));
      expect(source, contains('String? baseUrl'));
      expect(source, contains('List<Interceptor>? interceptors'));
      expect(source, contains('Duration connectTimeout'));
      expect(source, contains('Duration receiveTimeout'));
    });
  });

  // -------------------------------------------------------------------------
  // _defaultBaseUrl constant
  // -------------------------------------------------------------------------
  group('_defaultBaseUrl', () {
    test('non-empty baseUrl is embedded in _defaultBaseUrl constant', () {
      final source = _generate(_makeDoc(baseUrl: 'https://api.example.com'));
      expect(
        source,
        contains(
          "static const String _defaultBaseUrl = 'https://api.example.com'",
        ),
      );
    });

    test('empty baseUrl produces empty string constant', () {
      final source = _generate(_makeDoc(baseUrl: ''));
      expect(source, contains("static const String _defaultBaseUrl = ''"));
    });
  });

  // -------------------------------------------------------------------------
  // bearerAuth factory
  // -------------------------------------------------------------------------
  group('bearerAuth factory', () {
    test(
      'http/bearer scheme → source contains static Interceptor bearerAuth',
      () {
        final doc = _makeDoc(
          securitySchemes: {
            'bearerAuth': const SecurityScheme(
              name: 'bearerAuth',
              type: 'http',
              scheme: 'bearer',
            ),
          },
        );
        final source = _generate(doc);
        expect(source, contains('static Interceptor bearerAuth(String token)'));
      },
    );

    test('no bearer scheme → no bearerAuth in source', () {
      final source = _generate(_makeDoc());
      expect(source, isNot(contains('bearerAuth')));
    });
  });

  // -------------------------------------------------------------------------
  // apiKeyAuth factory (header)
  // -------------------------------------------------------------------------
  group('apiKeyAuth factory', () {
    test(
      'apiKey in:header → source contains static Interceptor apiKeyAuth',
      () {
        final doc = _makeDoc(
          securitySchemes: {
            'apiKeyHeader': const SecurityScheme(
              name: 'apiKeyHeader',
              type: 'apiKey',
              location: 'header',
              paramName: 'X-Api-Key',
            ),
          },
        );
        final source = _generate(doc);
        expect(source, contains('static Interceptor apiKeyAuth'));
        expect(source, contains('String apiKey'));
        expect(source, contains('String headerName'));
      },
    );

    test('no apiKey header scheme → no apiKeyAuth in source', () {
      final source = _generate(_makeDoc());
      expect(source, isNot(contains('apiKeyAuth')));
    });
  });

  // -------------------------------------------------------------------------
  // apiKeyQueryAuth factory (query)
  // -------------------------------------------------------------------------
  group('apiKeyQueryAuth factory', () {
    test(
      'apiKey in:query → source contains static Interceptor apiKeyQueryAuth',
      () {
        final doc = _makeDoc(
          securitySchemes: {
            'apiKeyQuery': const SecurityScheme(
              name: 'apiKeyQuery',
              type: 'apiKey',
              location: 'query',
              paramName: 'api_key',
            ),
          },
        );
        final source = _generate(doc);
        expect(source, contains('static Interceptor apiKeyQueryAuth'));
        expect(source, contains('String apiKey'));
        expect(source, contains('String paramName'));
      },
    );

    test('no apiKey query scheme → no apiKeyQueryAuth in source', () {
      final source = _generate(_makeDoc());
      expect(source, isNot(contains('apiKeyQueryAuth')));
    });
  });

  // -------------------------------------------------------------------------
  // basicAuth factory
  // -------------------------------------------------------------------------
  group('basicAuth factory', () {
    test(
      'http/basic scheme → source contains static Interceptor basicAuth',
      () {
        final doc = _makeDoc(
          securitySchemes: {
            'basicAuth': const SecurityScheme(
              name: 'basicAuth',
              type: 'http',
              scheme: 'basic',
            ),
          },
        );
        final source = _generate(doc);
        expect(source, contains('static Interceptor basicAuth'));
        expect(source, contains('String username'));
        expect(source, contains('String password'));
      },
    );

    test('no basic scheme → no basicAuth in source', () {
      final source = _generate(_makeDoc());
      expect(source, isNot(contains('basicAuth')));
    });
  });

  // -------------------------------------------------------------------------
  // Interceptors wired
  // -------------------------------------------------------------------------
  group('interceptors wired', () {
    test(
      'constructor body contains _dio.interceptors.addAll inside if block',
      () {
        final source = _generate(_makeDoc());
        expect(source, contains('_dio.interceptors.addAll(interceptors)'));
        expect(source, contains('if (interceptors != null)'));
      },
    );
  });

  // -------------------------------------------------------------------------
  // Duplicate scheme deduplication
  // -------------------------------------------------------------------------
  group('duplicate schemes', () {
    test('two bearer schemes → bearerAuth appears exactly once', () {
      // Duplicate schemes: only one factory emitted per type
      final doc = _makeDoc(
        securitySchemes: {
          'bearer1': const SecurityScheme(
            name: 'bearer1',
            type: 'http',
            scheme: 'bearer',
          ),
          'bearer2': const SecurityScheme(
            name: 'bearer2',
            type: 'http',
            scheme: 'bearer',
          ),
        },
      );
      final source = _generate(doc);
      final matches = RegExp(
        'static Interceptor bearerAuth',
      ).allMatches(source);
      expect(
        matches.length,
        equals(1),
        reason: 'bearerAuth should appear once',
      );
    });
  });

  // -------------------------------------------------------------------------
  // No part directives
  // -------------------------------------------------------------------------
  group('no part directives', () {
    test('generated source does not contain "part " or "part of "', () {
      final source = _generate(_makeDoc());
      expect(source, isNot(contains('part ')));
      expect(source, isNot(contains('part of ')));
    });
  });

  // -------------------------------------------------------------------------
  // File header
  // -------------------------------------------------------------------------
  group('file header', () {
    test('first line is the GENERATED CODE banner', () {
      final source = _generate(_makeDoc());
      final lines = source.split('\n');
      expect(lines.first, equals('// GENERATED CODE - DO NOT MODIFY BY HAND'));
    });

    test('second line is the @dart=3.0 directive', () {
      final source = _generate(_makeDoc());
      final lines = source.split('\n');
      expect(lines[1], equals('// @dart=3.0'));
    });
  });

  // -------------------------------------------------------------------------
  // onWarning callbacks (P2-06)
  // -------------------------------------------------------------------------
  group('onWarning callbacks', () {
    test('keyword clientName triggers onWarning with escaped name', () {
      final warnings = <String>[];
      final config = _makeConfig(clientName: 'base');
      final generator = AggregatorGenerator(onWarning: warnings.add);
      generator.generate(_makeDoc(), config);
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('"base"'));
      expect(warnings.first, contains('"base_"'));
    });

    test('non-keyword clientName does not trigger onWarning', () {
      final warnings = <String>[];
      final config = _makeConfig(clientName: 'ApiClient');
      final generator = AggregatorGenerator(onWarning: warnings.add);
      generator.generate(_makeDoc(), config);
      expect(warnings, isEmpty);
    });

    test('unknown auth scheme type triggers onWarning', () {
      final warnings = <String>[];
      final doc = _makeDoc(
        securitySchemes: {
          'oauth2Scheme': const SecurityScheme(
            name: 'oauth2Scheme',
            type: 'oauth2',
          ),
        },
      );
      final config = _makeConfig();
      final generator = AggregatorGenerator(onWarning: warnings.add);
      generator.generate(doc, config);
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('oauth2'));
    });

    test('known auth scheme does not trigger onWarning', () {
      final warnings = <String>[];
      final doc = _makeDoc(
        securitySchemes: {
          'bearerAuth': const SecurityScheme(
            name: 'bearerAuth',
            type: 'http',
            scheme: 'bearer',
          ),
        },
      );
      final config = _makeConfig();
      final generator = AggregatorGenerator(onWarning: warnings.add);
      generator.generate(doc, config);
      expect(warnings, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Idempotent output
  // -------------------------------------------------------------------------
  group('idempotent output', () {
    test('two calls with the same inputs produce identical string output', () {
      final doc = _makeDoc(
        operations: [
          _op('users', path: '/users'),
          _op('products', path: '/products'),
        ],
      );
      final source1 = _generate(doc);
      final source2 = _generate(doc);
      expect(source1, equals(source2));
    });
  });

  // -------------------------------------------------------------------------
  // Import path consistency (B2) — must match ServiceGenerator._tagToSnake()
  // ServiceGenerator: tag.trim().toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '_')
  // -------------------------------------------------------------------------
  group('import path consistency (B2)', () {
    test(
      'tag "pet store" → import line is exactly: import \'services/pet_store_api.dart\';',
      () {
        // B2: space-separated tag → snake_case with underscore
        final doc = _makeDoc(operations: [_op('pet store')]);
        final source = _generate(doc);
        expect(source, contains("import 'services/pet_store_api.dart';"));
      },
    );

    test(
      'tag "Pet-Store" → import line is exactly: import \'services/pet_store_api.dart\';',
      () {
        // B2: hyphen-separated tag → snake_case with underscore
        final doc = _makeDoc(operations: [_op('Pet-Store')]);
        final source = _generate(doc);
        expect(source, contains("import 'services/pet_store_api.dart';"));
      },
    );

    test(
      'tag "PetStore" → import line is exactly: import \'services/petstore_api.dart\';',
      () {
        // B2: PascalCase tag → fully lowercase (no separator insertion)
        // ServiceGenerator._tagToSnake: tag.trim().toLowerCase() → 'petstore'
        final doc = _makeDoc(operations: [_op('PetStore')]);
        final source = _generate(doc);
        expect(source, contains("import 'services/petstore_api.dart';"));
      },
    );
  });
}
