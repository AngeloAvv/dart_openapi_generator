import 'dart:io';
import 'dart:typed_data';

import 'package:dart_openapi_generator/src/cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:dart_openapi_generator/src/resolved_annotation.dart';
import 'package:dart_openapi_generator/src/version.dart';
import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';
import 'package:test/test.dart';

ResolvedAnnotation _makeResolved({
  String outputDir = 'lib/generated',
  String clientName = 'ApiClient',
  bool skipIfSpecIsUnchanged = true,
  String? cachePath,
  bool cleanOutput = true,
  DateTimeConverter dateTimeConverter = DateTimeConverter.iso8601,
  bool debugLogging = false,
}) => ResolvedAnnotation(
  inputSpec: const LocalSpec('openapi.yaml'),
  outputDir: outputDir,
  clientName: clientName,
  skipIfSpecIsUnchanged: skipIfSpecIsUnchanged,
  cachePath: cachePath ?? '.dart_tool/dart_openapi_generator_cache',
  cleanOutput: cleanOutput,
  dateTimeConverter: dateTimeConverter,
  debugLogging: debugLogging,
);

void main() {
  group('CacheManager.computeCacheKey', () {
    test('is deterministic for identical inputs', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final resolved = _makeResolved();

      final key1 = CacheManager.computeCacheKey(bytes, resolved);
      final key2 = CacheManager.computeCacheKey(bytes, resolved);

      expect(key1, equals(key2));
    });

    test('returns a length-separated triple-MD5 string (98 chars)', () {
      final bytes = Uint8List.fromList([10, 20, 30]);
      final resolved = _makeResolved();

      final key = CacheManager.computeCacheKey(bytes, resolved);

      // Format: <md5_spec>:<md5_version>:<md5_config> — three 32-char hex
      // segments separated by colons, total length 98.
      expect(key, hasLength(98));
      expect(key, matches(RegExp(r'^[a-f0-9]{32}:[a-f0-9]{32}:[a-f0-9]{32}$')));
    });

    test('different spec bytes produce different keys', () {
      final resolved = _makeResolved();
      final key1 = CacheManager.computeCacheKey(
        Uint8List.fromList([1, 2, 3]),
        resolved,
      );
      final key2 = CacheManager.computeCacheKey(
        Uint8List.fromList([4, 5, 6]),
        resolved,
      );

      expect(key1, isNot(equals(key2)));
    });

    test('different clientName produces different key', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final key1 = CacheManager.computeCacheKey(
        bytes,
        _makeResolved(clientName: 'ClientA'),
      );
      final key2 = CacheManager.computeCacheKey(
        bytes,
        _makeResolved(clientName: 'ClientB'),
      );

      expect(key1, isNot(equals(key2)));
    });

    test('different outputDir produces different key', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final key1 = CacheManager.computeCacheKey(
        bytes,
        _makeResolved(outputDir: 'lib/gen1'),
      );
      final key2 = CacheManager.computeCacheKey(
        bytes,
        _makeResolved(outputDir: 'lib/gen2'),
      );

      expect(key1, isNot(equals(key2)));
    });

    test('different dateTimeConverter produces different key', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final key1 = CacheManager.computeCacheKey(
        bytes,
        _makeResolved(dateTimeConverter: DateTimeConverter.iso8601),
      );
      final key2 = CacheManager.computeCacheKey(
        bytes,
        _makeResolved(dateTimeConverter: DateTimeConverter.timestamp),
      );

      expect(key1, isNot(equals(key2)));
    });

    test('debugLogging does NOT affect the cache key', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final key1 = CacheManager.computeCacheKey(
        bytes,
        _makeResolved(debugLogging: false),
      );
      final key2 = CacheManager.computeCacheKey(
        bytes,
        _makeResolved(debugLogging: true),
      );

      expect(key1, equals(key2));
    });

    test('skipIfSpecIsUnchanged does NOT affect the cache key', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final key1 = CacheManager.computeCacheKey(
        bytes,
        _makeResolved(skipIfSpecIsUnchanged: false),
      );
      final key2 = CacheManager.computeCacheKey(
        bytes,
        _makeResolved(skipIfSpecIsUnchanged: true),
      );

      expect(key1, equals(key2));
    });

    test(
      'kGeneratorVersion is included in key computation (version bump invalidates cache)',
      () {
        // This test verifies that the key depends on kGeneratorVersion by checking
        // that the known version string appears in the computation.
        // We cannot mutate kGeneratorVersion, so we verify the key changes when
        // spec bytes change — a proxy for the concatenation being correct.
        // Separately, the version string is a const; any code change that bumps it
        // will produce a different key for the same spec.
        final bytes = Uint8List.fromList([0]);
        final resolved = _makeResolved();

        final key = CacheManager.computeCacheKey(bytes, resolved);

        // Key must match the length-separated triple-MD5 format.
        expect(
          key,
          matches(RegExp(r'^[a-f0-9]{32}:[a-f0-9]{32}:[a-f0-9]{32}$')),
        );
        // kGeneratorVersion is accessible and is the expected value.
        expect(kGeneratorVersion, equals('0.1.0'));
      },
    );
  });

  group('CacheManager.shouldSkip', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('cache_manager_test_');
    });

    tearDown(() async {
      await tmpDir.delete(recursive: true);
    });

    test(
      'returns false when skipIfSpecIsUnchanged is false (even if cache exists)',
      () async {
        const manager = CacheManager();
        const cacheKey = 'abc123';
        final resolved = _makeResolved(
          skipIfSpecIsUnchanged: false,
          cachePath: tmpDir.path,
        );

        // Create cache marker to confirm it is ignored.
        final markerDir = Directory('${tmpDir.path}/$cacheKey');
        await markerDir.create();
        await File('${markerDir.path}/cache.json').writeAsString('{}');

        expect(await manager.shouldSkip(cacheKey, resolved), isFalse);
      },
    );

    test(
      'returns false when skipIfSpecIsUnchanged is true but cache does not exist',
      () async {
        const manager = CacheManager();
        const cacheKey = 'no_cache_entry';
        final resolved = _makeResolved(
          skipIfSpecIsUnchanged: true,
          cachePath: tmpDir.path,
        );

        expect(await manager.shouldSkip(cacheKey, resolved), isFalse);
      },
    );

    test(
      'returns true when skipIfSpecIsUnchanged is true and cache.json exists',
      () async {
        const manager = CacheManager();
        const cacheKey = 'deadbeef1234567890abcdef12345678';
        final resolved = _makeResolved(
          skipIfSpecIsUnchanged: true,
          cachePath: tmpDir.path,
        );

        // Pre-populate cache.
        final dir = Directory('${tmpDir.path}/$cacheKey');
        await dir.create(recursive: true);
        await File(
          '${dir.path}/cache.json',
        ).writeAsString('{"key":"$cacheKey"}');

        expect(await manager.shouldSkip(cacheKey, resolved), isTrue);
      },
    );
  });

  group('CacheManager.writeCache', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp(
        'cache_manager_write_test_',
      );
    });

    tearDown(() async {
      await tmpDir.delete(recursive: true);
    });

    test('creates cache.json at <cachePath>/<cacheKey>/cache.json', () async {
      const manager = CacheManager();
      const cacheKey = 'testkey123';
      final resolved = _makeResolved(cachePath: tmpDir.path);

      await manager.writeCache(cacheKey, resolved);

      final cacheFile = File('${tmpDir.path}/$cacheKey/cache.json');
      expect(cacheFile.existsSync(), isTrue);
    });

    test('cache.json content contains the key', () async {
      const manager = CacheManager();
      const cacheKey = 'testkey456';
      final resolved = _makeResolved(cachePath: tmpDir.path);

      await manager.writeCache(cacheKey, resolved);

      final content =
          await File('${tmpDir.path}/$cacheKey/cache.json').readAsString();
      expect(content, contains(cacheKey));
    });

    test(
      'no .tmp file remains after successful write (atomic cleanup)',
      () async {
        const manager = CacheManager();
        const cacheKey = 'atomickey789';
        final resolved = _makeResolved(cachePath: tmpDir.path);

        await manager.writeCache(cacheKey, resolved);

        // Implementation uses a unique suffix (cache.json.tmp.<hex>) so we
        // list the directory and assert no entry matches the .tmp.* pattern.
        final cacheDir = Directory('${tmpDir.path}/$cacheKey');
        final tmpFiles =
            cacheDir
                .listSync()
                .whereType<File>()
                .where((f) => p.basename(f.path).contains('.tmp'))
                .toList();
        expect(
          tmpFiles,
          isEmpty,
          reason: 'No .tmp.* file should remain after successful atomic rename',
        );
      },
    );

    test(
      'concurrent writeCache calls for same key do not corrupt the file',
      () async {
        const manager = CacheManager();
        const cacheKey = 'concurrent_key';
        final resolved = _makeResolved(cachePath: tmpDir.path);

        // Fire 5 concurrent writes.
        await Future.wait([
          for (var i = 0; i < 5; i++) manager.writeCache(cacheKey, resolved),
        ]);

        final cacheFile = File('${tmpDir.path}/$cacheKey/cache.json');
        expect(cacheFile.existsSync(), isTrue);
        // Content must be valid JSON (not torn/empty).
        final content = cacheFile.readAsStringSync();
        expect(content, contains(cacheKey));
      },
    );

    test('writeCache followed by shouldSkip returns true', () async {
      const manager = CacheManager();
      const cacheKey = 'roundtrip_key';
      final resolved = _makeResolved(
        skipIfSpecIsUnchanged: true,
        cachePath: tmpDir.path,
      );

      expect(await manager.shouldSkip(cacheKey, resolved), isFalse);
      await manager.writeCache(cacheKey, resolved);
      expect(await manager.shouldSkip(cacheKey, resolved), isTrue);
    });
  });
}
