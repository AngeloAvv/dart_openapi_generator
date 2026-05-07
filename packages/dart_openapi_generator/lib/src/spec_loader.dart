import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:source_gen/source_gen.dart';

import 'resolved_annotation.dart';

/// Loads raw OpenAPI spec bytes from a [ResolvedAnnotation]'s [InputSpec].
///
/// Implementations: [LocalSpecLoader] (disk) and [RemoteSpecLoader] (HTTPS).
/// Returns a [Uint8List] of raw bytes; format sniffing (YAML vs JSON) is
/// handled by the spec parser.
abstract interface class SpecLoader {
  /// Loads spec bytes. Throws [InvalidGenerationSource] on any error.
  Future<Uint8List> load(ResolvedAnnotation resolved);
}

/// Loads spec bytes from a local file path.
///
/// [ResolvedAnnotation.inputSpec] must be a [LocalSpec]. Relative paths are
/// resolved against [Directory.current] (the package root when invoked via
/// `dart run build_runner`), or [baseDirOverride] when injected for testing.
/// Absolute paths (starting with `/`) are used as-is.
final class LocalSpecLoader implements SpecLoader {
  /// Override the base directory used to resolve relative paths.
  /// Defaults to [Directory.current] when null. Inject in tests to avoid
  /// coupling to the process working directory.
  final String? baseDirOverride;

  const LocalSpecLoader({this.baseDirOverride});

  @override
  Future<Uint8List> load(ResolvedAnnotation resolved) async {
    final spec = resolved.inputSpec as LocalSpec;
    final file = _resolveFile(spec.path);
    if (!await file.exists()) {
      throw InvalidGenerationSource(
        'LocalSpec file not found: ${file.absolute.path}\n'
        'Ensure the path is relative to the package root '
        '(where pubspec.yaml lives).',
        todo: "Check that '${spec.path}' exists relative to the package root.",
      );
    }
    return file.readAsBytes();
  }

  File _resolveFile(String path) {
    if (p.isAbsolute(path)) return File(path);
    return File(p.join(baseDirOverride ?? Directory.current.path, path));
  }
}

/// Loads spec bytes from an HTTPS URL.
///
/// [ResolvedAnnotation.inputSpec] must be a [RemoteSpec]. Only `https` scheme
/// is accepted — `http` URLs are rejected before any network request is made.
/// A 30-second timeout is enforced (no user-facing override for v0.1.0).
/// Auth header values are NEVER written to any log.
///
/// Accepts an optional [httpClient] for test injection; uses [http.Client]
/// by default.
final class RemoteSpecLoader implements SpecLoader {
  final http.Client? _client;

  const RemoteSpecLoader({http.Client? httpClient}) : _client = httpClient;

  @override
  Future<Uint8List> load(ResolvedAnnotation resolved) async {
    final spec = resolved.inputSpec as RemoteSpec;
    final Uri uri;
    try {
      uri = Uri.parse(spec.url);
    } on FormatException {
      throw InvalidGenerationSource(
        'RemoteSpec URL is malformed: ${spec.url}',
        todo: "Provide a valid HTTPS URL in your RemoteSpec annotation.",
      );
    }
    if (uri.scheme != 'https') {
      throw InvalidGenerationSource(
        'RemoteSpec URL must use HTTPS. Got: ${spec.url}\n'
        'Change the URL scheme to https.',
        todo: "Update RemoteSpec URL to start with 'https://'.",
      );
    }
    final client = _client ?? http.Client();
    final bool didCreateClient = _client == null;
    try {
      final http.Response response;
      try {
        response = await client
            .get(uri, headers: spec.headers ?? const {})
            .timeout(const Duration(seconds: 30));
      } on TimeoutException {
        throw InvalidGenerationSource(
          'RemoteSpec fetch timed out after 30 seconds: ${spec.url}',
          todo: 'Check network connectivity or the remote server availability.',
        );
      } on Exception catch (e) {
        throw InvalidGenerationSource(
          'RemoteSpec network error: $e',
          todo:
              'Check network connectivity and the remote server availability.',
        );
      }
      // P0-05: Verify the final URL after any redirects is still HTTPS.
      // http.Client follows 301/302 transparently; a server-side redirect to
      // plain HTTP would transmit auth headers in plaintext.
      final finalScheme = response.request?.url.scheme;
      if (finalScheme != null && finalScheme != 'https') {
        throw InvalidGenerationSource(
          'RemoteSpec redirected to non-HTTPS URL: ${response.request?.url}',
          todo:
              'Ensure the remote server does not redirect to a plain HTTP URL.',
        );
      }
      if (response.statusCode != 200) {
        throw InvalidGenerationSource(
          'Failed to fetch spec: HTTP ${response.statusCode} from ${spec.url}',
          todo:
              'Verify the URL is correct and the server returns a 200 response.',
        );
      }
      return response.bodyBytes;
    } finally {
      if (didCreateClient) client.close();
    }
  }
}
