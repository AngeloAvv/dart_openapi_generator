import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_openapi_generator/src/resolved_annotation.dart';
import 'package:dart_openapi_generator/src/spec_loader.dart';
import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';
import 'package:http/http.dart' as http;
import 'package:source_gen/source_gen.dart';
import 'package:test/test.dart';

/// Minimal mock http.Client that returns a preset [http.Response].
///
/// Constructed with a status code and body bytes. Captures the last
/// request URI and headers for assertion in tests.
class _MockHttpClient extends http.BaseClient {
  final int statusCode;
  final Uint8List bodyBytes;

  Uri? lastRequestUri;
  Map<String, String>? lastRequestHeaders;

  _MockHttpClient({required this.statusCode, required this.bodyBytes});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequestUri = request.url;
    lastRequestHeaders = request.headers;
    return http.StreamedResponse(Stream.value(bodyBytes), statusCode);
  }
}

ResolvedAnnotation _makeResolved({
  InputSpec? inputSpec,
  String outputDir = 'lib/generated',
  String clientName = 'ApiClient',
  bool skipIfSpecIsUnchanged = true,
  String cachePath = '.dart_tool/dart_openapi_generator_cache',
  bool cleanOutput = true,
  DateTimeConverter dateTimeConverter = DateTimeConverter.iso8601,
  bool debugLogging = false,
}) => ResolvedAnnotation(
  inputSpec: inputSpec ?? const LocalSpec('openapi.yaml'),
  outputDir: outputDir,
  clientName: clientName,
  skipIfSpecIsUnchanged: skipIfSpecIsUnchanged,
  cachePath: cachePath,
  cleanOutput: cleanOutput,
  dateTimeConverter: dateTimeConverter,
  debugLogging: debugLogging,
);

void main() {
  group('LocalSpecLoader', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('spec_loader_test_');
    });

    tearDown(() async {
      await tmpDir.delete(recursive: true);
    });

    test('loads bytes from an absolute file path', () async {
      final file = File('${tmpDir.path}/api.yaml');
      await file.writeAsString('openapi: 3.0.0');

      const loader = LocalSpecLoader();
      final resolved = _makeResolved(inputSpec: LocalSpec(file.path));
      final bytes = await loader.load(resolved);

      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes), equals('openapi: 3.0.0'));
    });

    test(
      'throws InvalidGenerationSource with absolute path when file is missing',
      () async {
        final missingPath = '${tmpDir.path}/nonexistent.yaml';
        const loader = LocalSpecLoader();
        final resolved = _makeResolved(inputSpec: LocalSpec(missingPath));

        await expectLater(
          () => loader.load(resolved),
          throwsA(
            isA<InvalidGenerationSource>().having(
              (e) => e.message,
              'message',
              contains(missingPath),
            ),
          ),
        );
      },
    );

    test('resolves relative path against baseDirOverride', () async {
      // Write a spec file in tmpDir, then load it via a relative path by
      // injecting tmpDir as the base directory. This exercises the
      // p.join(baseDirOverride, path) branch in _resolveFile.
      final file = File('${tmpDir.path}/relative_test.yaml');
      await file.writeAsString('info: test');

      final loader = LocalSpecLoader(baseDirOverride: tmpDir.path);
      final resolved = _makeResolved(
        inputSpec: const LocalSpec('relative_test.yaml'),
      );
      final bytes = await loader.load(resolved);
      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes), equals('info: test'));
    });
  });

  group('RemoteSpecLoader', () {
    test('returns body bytes on 200 response', () async {
      final expected = Uint8List.fromList('openapi: 3.1.0'.codeUnits);
      final mockClient = _MockHttpClient(statusCode: 200, bodyBytes: expected);
      final loader = RemoteSpecLoader(httpClient: mockClient);
      final resolved = _makeResolved(
        inputSpec: const RemoteSpec('https://example.com/api.yaml'),
      );

      final bytes = await loader.load(resolved);

      expect(bytes, equals(expected));
    });

    test(
      'throws InvalidGenerationSource for non-https URL before network call',
      () async {
        final mockClient = _MockHttpClient(
          statusCode: 200,
          bodyBytes: Uint8List(0),
        );
        final loader = RemoteSpecLoader(httpClient: mockClient);
        final resolved = _makeResolved(
          inputSpec: const RemoteSpec('http://example.com/api.yaml'),
        );

        await expectLater(
          () => loader.load(resolved),
          throwsA(isA<InvalidGenerationSource>()),
        );
        // Verify no network call was made (lastRequestUri is null).
        expect(mockClient.lastRequestUri, isNull);
      },
    );

    test(
      'throws InvalidGenerationSource with status code and URL on non-200 response',
      () async {
        final mockClient = _MockHttpClient(
          statusCode: 404,
          bodyBytes: Uint8List(0),
        );
        final loader = RemoteSpecLoader(httpClient: mockClient);
        final resolved = _makeResolved(
          inputSpec: const RemoteSpec('https://example.com/api.yaml'),
        );

        await expectLater(
          () => loader.load(resolved),
          throwsA(
            isA<InvalidGenerationSource>().having(
              (e) => e.message,
              'message',
              allOf(contains('404'), contains('https://example.com/api.yaml')),
            ),
          ),
        );
      },
    );

    test('passes headers to HTTP request', () async {
      final expected = Uint8List.fromList('spec'.codeUnits);
      final mockClient = _MockHttpClient(statusCode: 200, bodyBytes: expected);
      final loader = RemoteSpecLoader(httpClient: mockClient);
      final resolved = _makeResolved(
        inputSpec: const RemoteSpec(
          'https://example.com/api.yaml',
          headers: {'Authorization': 'Bearer secret-token'},
        ),
      );

      await loader.load(resolved);

      // Header was forwarded to the HTTP client.
      expect(
        mockClient.lastRequestHeaders,
        containsPair('Authorization', 'Bearer secret-token'),
      );
    });

    test('auth header value does not appear in exception messages', () async {
      final mockClient = _MockHttpClient(
        statusCode: 403,
        bodyBytes: Uint8List(0),
      );
      final loader = RemoteSpecLoader(httpClient: mockClient);
      final resolved = _makeResolved(
        inputSpec: const RemoteSpec(
          'https://example.com/api.yaml',
          headers: {'Authorization': 'Bearer secret-token-xyz'},
        ),
      );

      try {
        await loader.load(resolved);
        fail('Expected InvalidGenerationSource');
      } on InvalidGenerationSource catch (e) {
        expect(
          e.message,
          isNot(contains('secret-token-xyz')),
          reason: 'Auth header value must not appear in error messages',
        );
      }
    });
  });
}
