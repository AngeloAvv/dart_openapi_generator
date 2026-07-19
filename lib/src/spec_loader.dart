import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Reads raw OpenAPI spec bytes from a local file path, synchronously.
///
/// Synchronous by design: this must be callable from the builder factory
/// (`Builder Function(BuilderOptions)`, not `Future<Builder> Function(...)`)
/// so the spec can be parsed before `buildExtensions` is computed. Remote
/// specs are not supported for this reason (no synchronous HTTP in Dart).
///
/// Relative paths are resolved against [baseDirOverride] when given
/// (injected in tests), otherwise [Directory.current] — the package root
/// when invoked via `dart run build_runner`. Absolute paths are used as-is.
Uint8List readLocalSpec(String path, {String? baseDirOverride}) {
  final file = _resolveFile(path, baseDirOverride);
  if (!file.existsSync()) {
    throw ArgumentError(
      'dart_openapi_generator: input_spec file not found: '
      '${file.absolute.path}\n'
      "Ensure '$path' exists relative to the package root "
      '(where pubspec.yaml lives).',
    );
  }
  return file.readAsBytesSync();
}

File _resolveFile(String path, String? baseDirOverride) {
  if (p.isAbsolute(path)) return File(path);
  return File(p.join(baseDirOverride ?? Directory.current.path, path));
}
