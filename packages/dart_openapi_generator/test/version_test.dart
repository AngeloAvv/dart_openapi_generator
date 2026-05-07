import 'dart:io';

import 'package:dart_openapi_generator/src/version.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Locate the dart_openapi_generator pubspec.yaml by searching upward from
/// [Directory.current] and also by checking the known monorepo path.
File? _findPubspec() {
  // Candidate search roots: current directory and up.
  var dir = Directory.current.path;
  for (var i = 0; i < 8; i++) {
    for (final relative in [
      'pubspec.yaml',
      p.join('packages', 'dart_openapi_generator', 'pubspec.yaml'),
    ]) {
      final candidate = File(p.join(dir, relative));
      if (candidate.existsSync()) {
        final content = loadYaml(candidate.readAsStringSync()) as YamlMap;
        if (content['name'] == 'dart_openapi_generator') {
          return candidate;
        }
      }
    }
    final parent = p.dirname(dir);
    if (parent == dir) break; // filesystem root
    dir = parent;
  }
  return null;
}

void main() {
  test('kGeneratorVersion matches version field in pubspec.yaml', () {
    final pubspecFile = _findPubspec();

    expect(
      pubspecFile,
      isNotNull,
      reason:
          'Could not locate packages/dart_openapi_generator/pubspec.yaml. '
          'Run the test from the repo root or package root.',
    );

    final pubspec = loadYaml(pubspecFile!.readAsStringSync()) as YamlMap;
    final pubspecVersion = pubspec['version'] as String;

    expect(
      kGeneratorVersion,
      equals(pubspecVersion),
      reason:
          'kGeneratorVersion ("$kGeneratorVersion") does not match the '
          'version in pubspec.yaml ("$pubspecVersion"). '
          'Update lib/src/version.dart when bumping the package version.',
    );
  });
}
