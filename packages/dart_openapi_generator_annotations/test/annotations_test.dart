import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';
import 'package:test/test.dart';

void main() {
  group('OpenApiGenerator', () {
    test('const construction with required fields only uses correct defaults',
        () {
      const annotation = OpenApiGenerator(
        inputSpec: LocalSpec('openapi/api.yaml'),
        outputDir: 'lib/generated',
      );
      expect(annotation.clientName, equals('ApiClient'));
      expect(annotation.skipIfSpecIsUnchanged, isTrue);
      expect(
        annotation.cachePath,
        equals('.dart_tool/dart_openapi_generator_cache'),
      );
      expect(annotation.cleanOutput, isTrue);
      expect(annotation.dateTimeConverter, equals(DateTimeConverter.iso8601));
      expect(annotation.debugLogging, isFalse);
    });

    test('const construction with all fields set', () {
      const annotation = OpenApiGenerator(
        inputSpec: RemoteSpec(
          'https://example.com/api.json',
          headers: {'Authorization': 'Bearer token'},
        ),
        outputDir: 'lib/out',
        clientName: 'FooClient',
        skipIfSpecIsUnchanged: false,
        cachePath: '.cache',
        cleanOutput: false,
        dateTimeConverter: DateTimeConverter.timestamp,
        debugLogging: true,
      );
      expect(annotation.clientName, equals('FooClient'));
      expect(annotation.skipIfSpecIsUnchanged, isFalse);
      expect(annotation.cachePath, equals('.cache'));
      expect(annotation.cleanOutput, isFalse);
      expect(annotation.dateTimeConverter, equals(DateTimeConverter.timestamp));
      expect(annotation.debugLogging, isTrue);
    });

    test('inputSpec and outputDir are correctly stored', () {
      const spec = LocalSpec('openapi/api.yaml');
      const annotation = OpenApiGenerator(
        inputSpec: spec,
        outputDir: 'lib/generated',
      );
      expect(annotation.inputSpec, same(spec));
      expect(annotation.outputDir, equals('lib/generated'));
    });
  });

  group('LocalSpec', () {
    test('const construction stores path', () {
      const spec = LocalSpec('openapi/api.yaml');
      expect(spec.path, equals('openapi/api.yaml'));
    });

    test('is a subtype of InputSpec', () {
      const spec = LocalSpec('some/path.yaml');
      expect(spec, isA<InputSpec>());
    });
  });

  group('RemoteSpec', () {
    test('const construction without headers sets headers to null', () {
      const spec = RemoteSpec('https://example.com/api.json');
      expect(spec.url, equals('https://example.com/api.json'));
      expect(spec.headers, isNull);
    });

    test('const construction with headers stores headers map', () {
      const spec = RemoteSpec(
        'https://example.com/api.json',
        headers: {'Authorization': 'Bearer token', 'X-Api-Key': 'key123'},
      );
      expect(spec.headers,
          equals({'Authorization': 'Bearer token', 'X-Api-Key': 'key123'}));
    });

    test('is a subtype of InputSpec', () {
      const spec = RemoteSpec('https://example.com/api.json');
      expect(spec, isA<InputSpec>());
    });
  });

  group('InputSpec sealed switch', () {
    test(
        'exhaustive switch over LocalSpec and RemoteSpec compiles and dispatches correctly',
        () {
      InputSpec spec = const LocalSpec('test.yaml');
      final result = switch (spec) {
        LocalSpec(:final path) => 'local:$path',
        RemoteSpec(:final url) => 'remote:$url',
      };
      expect(result, equals('local:test.yaml'));

      final InputSpec spec2 = const RemoteSpec('https://example.com/api.json');
      final result2 = switch (spec2) {
        LocalSpec(:final path) => 'local:$path',
        RemoteSpec(:final url) => 'remote:$url',
      };
      expect(result2, equals('remote:https://example.com/api.json'));
    });
  });

  group('DateTimeConverter', () {
    test('has exactly two values', () {
      expect(DateTimeConverter.values, hasLength(2));
    });

    test('contains iso8601 and timestamp', () {
      expect(
        DateTimeConverter.values,
        containsAll([DateTimeConverter.iso8601, DateTimeConverter.timestamp]),
      );
    });
  });
}
