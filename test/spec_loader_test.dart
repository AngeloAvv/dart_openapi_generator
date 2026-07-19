import 'dart:io';

import 'package:dart_openapi_generator/src/spec_loader.dart';
import 'package:test/test.dart';

void main() {
  group('readLocalSpec', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('spec_loader_test_');
    });

    tearDown(() async {
      await tmpDir.delete(recursive: true);
    });

    test('loads bytes from an absolute file path', () {
      final file = File('${tmpDir.path}/api.yaml');
      file.writeAsStringSync('openapi: 3.0.0');

      final bytes = readLocalSpec(file.path);

      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes), equals('openapi: 3.0.0'));
    });

    test('throws ArgumentError with path when file is missing', () {
      final missingPath = '${tmpDir.path}/nonexistent.yaml';

      expect(
        () => readLocalSpec(missingPath),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains(missingPath),
          ),
        ),
      );
    });

    test('resolves relative path against baseDirOverride', () {
      // Write a spec file in tmpDir, then load it via a relative path by
      // injecting tmpDir as the base directory. This exercises the
      // p.join(baseDirOverride, path) branch in _resolveFile.
      final file = File('${tmpDir.path}/relative_test.yaml');
      file.writeAsStringSync('info: test');

      final bytes = readLocalSpec(
        'relative_test.yaml',
        baseDirOverride: tmpDir.path,
      );

      expect(bytes, isNotEmpty);
      expect(String.fromCharCodes(bytes), equals('info: test'));
    });
  });
}
