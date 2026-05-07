import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'resolved_annotation.dart';
import 'version.dart';

// Module-level singleton so concurrent writeCache calls share one CSPRNG and
// never produce the same seed (avoids same-tick collision with Random()).
final _random = Random.secure();

/// Manages the MD5-keyed spec cache for [dart_openapi_generator].
///
/// The cache prevents redundant codegen runs when the spec and generator
/// configuration have not changed. Each cache entry lives at:
///   `<cachePath>/<cacheKey>/cache.json`
///
/// All writes are atomic (temp-file + rename) to survive concurrent
/// `dart run build_runner` invocations on the same project.
final class CacheManager {
  const CacheManager();

  /// Computes the MD5 hex cache key from [specBytes], the hardcoded
  /// [kGeneratorVersion], and a canonical JSON representation of the
  /// codegen-affecting annotation fields.
  ///
  /// Only [ResolvedAnnotation.outputDir], [ResolvedAnnotation.clientName],
  /// [ResolvedAnnotation.dateTimeConverter], and [ResolvedAnnotation.cleanOutput]
  /// are included — fields that do not affect generated output
  /// (`debugLogging`, `skipIfSpecIsUnchanged`, `cachePath`) are excluded.
  ///
  /// Keys are sorted alphabetically to ensure determinism across Dart Map
  /// iteration orders. Bumping [kGeneratorVersion] always invalidates all
  /// prior cache entries.
  static String computeCacheKey(
    Uint8List specBytes,
    ResolvedAnnotation resolved,
  ) {
    // Keys sorted alphabetically (c, cl, d, o) — maintains canonical form.
    final configJson = jsonEncode(<String, dynamic>{
      'cleanOutput': resolved.cleanOutput,
      'clientName': resolved.clientName,
      'dateTimeConverter': resolved.dateTimeConverter.name,
      'outputDir': resolved.outputDir,
    });
    final specHash = md5.convert(specBytes).toString();
    final versionHash = md5.convert(utf8.encode(kGeneratorVersion)).toString();
    final configHash = md5.convert(utf8.encode(configJson)).toString();
    return '$specHash:$versionHash:$configHash';
  }

  /// Returns `true` when the builder should skip codegen for this [cacheKey].
  ///
  /// Returns `true` only when BOTH conditions hold:
  /// 1. [ResolvedAnnotation.skipIfSpecIsUnchanged] is `true`.
  /// 2. A cache marker file exists at `<cachePath>/<cacheKey>/cache.json`.
  ///
  /// Always returns `false` when [skipIfSpecIsUnchanged] is `false`,
  /// regardless of whether a cache entry exists.
  Future<bool> shouldSkip(String cacheKey, ResolvedAnnotation resolved) async {
    if (!resolved.skipIfSpecIsUnchanged) return false;
    final marker = File(p.join(resolved.cachePath, cacheKey, 'cache.json'));
    return marker.exists();
  }

  /// Writes a cache marker for [cacheKey] atomically.
  ///
  /// Creates the cache directory if it does not exist, writes to a `.tmp`
  /// file first, then renames to the final `cache.json` path. Rename is
  /// atomic on the same filesystem, preventing torn writes from concurrent
  /// build invocations.
  ///
  /// Called after every successful spec load, regardless of
  /// [ResolvedAnnotation.skipIfSpecIsUnchanged].
  Future<void> writeCache(String cacheKey, ResolvedAnnotation resolved) async {
    final dir = Directory(p.join(resolved.cachePath, cacheKey));
    await dir.create(recursive: true);
    final finalFile = File(p.join(dir.path, 'cache.json'));
    // Use a unique suffix per invocation so concurrent writes don't share the
    // same .tmp path — each rename is independent and atomic.
    final suffix = _random.nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
    final tmpFile = File('${finalFile.path}.tmp.$suffix');
    var renamed = false;
    try {
      await tmpFile.writeAsString(
        '{"key":"$cacheKey","version":"$kGeneratorVersion"}',
      );
      await tmpFile.rename(finalFile.path);
      renamed = true;
    } finally {
      if (!renamed && tmpFile.existsSync()) {
        await tmpFile.delete();
      }
    }
  }
}
