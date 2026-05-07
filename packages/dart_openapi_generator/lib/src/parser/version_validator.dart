import '../model/openapi_parse_exception.dart';
import 'source_map.dart';

/// Validates the `openapi:` version field from a parsed spec document.
///
/// Accepts OpenAPI 3.0.x, 3.1.x, and 3.2.x (regex `^3\.\d+\.\d+$`).
/// Throws [OpenApiParseException] with [jsonPointer] = `'#/openapi'` for:
///   - Any 2.x (Swagger) version
///   - Any unknown major (1.x, 4.x, etc.)
///   - Missing or null `openapi` field
///
/// [rawVersion] is the raw string value of the `openapi:` field.
/// [sourceMap] is used to attach source location to the thrown exception.
void validateVersion(String? rawVersion, SourceMap sourceMap) {
  const pointer = '#/openapi';

  if (rawVersion == null) {
    throw OpenApiParseException(
      'Missing required "openapi" field. '
      'This generator supports OpenAPI 3.0.x, 3.1.x, and 3.2.x.',
      jsonPointer: pointer,
      sourceSpan: sourceMap.spanAt(pointer),
    );
  }

  final versionRegex = RegExp(r'^3\.(\d+)\.(\d+)$');
  if (versionRegex.hasMatch(rawVersion)) {
    return; // Valid 3.x.x — accept
  }

  // Detect 2.x (Swagger) for specific error message
  if (rawVersion.startsWith('2.')) {
    throw OpenApiParseException(
      'Swagger 2.x ("$rawVersion") is not supported. '
      'This generator supports OpenAPI 3.0.x, 3.1.x, and 3.2.x only. '
      'Convert your spec to OpenAPI 3.x before using this generator.',
      jsonPointer: pointer,
      sourceSpan: sourceMap.spanAt(pointer),
    );
  }

  // Unknown major version
  final majorMatch = RegExp(r'^(\d+)\.').firstMatch(rawVersion);
  final found = majorMatch?.group(1) ?? rawVersion;
  throw OpenApiParseException(
    'Unsupported OpenAPI major version: "$found" (full value: "$rawVersion"). '
    'This generator supports 3.0.x, 3.1.x, and 3.2.x.',
    jsonPointer: pointer,
    sourceSpan: sourceMap.spanAt(pointer),
  );
}
