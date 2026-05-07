import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../model/openapi_parse_exception.dart';
import 'source_map.dart';

/// The result of sniffing and initially parsing a spec byte array.
///
/// [YamlSniffResult] — input was detected as YAML. Carries the plain
///   [map] (from `YamlMap.value`) and the pre-built [sourceMap].
/// [JsonSniffResult] — input was detected as JSON. Carries the plain
///   [map] (from `jsonDecode`). SourceMap is empty (spans unavailable).
@immutable
sealed class SniffResult {
  /// The spec content as a plain Dart `Map<String, dynamic>`.
  /// All subsequent parsing works from this map.
  final Map<String, dynamic> map;

  const SniffResult(this.map);
}

/// YAML-format spec result. [sourceMap] was populated during [loadYamlNode] traversal.
@immutable
final class YamlSniffResult extends SniffResult {
  final SourceMap sourceMap;
  const YamlSniffResult(super.map, this.sourceMap);
}

/// JSON-format spec result. No source spans available; [sourceMap] is always empty.
@immutable
final class JsonSniffResult extends SniffResult {
  /// Always [SourceMap.empty] — JSON input provides no span information.
  final SourceMap sourceMap;
  const JsonSniffResult(super.map) : sourceMap = const SourceMap.empty();
}

/// Sniffs [bytes] to determine YAML vs JSON format, parses accordingly,
/// and returns a [SniffResult] with the plain map and (for YAML) a [SourceMap].
///
/// Detection strategy: find the first non-whitespace byte.
///   - `{` (0x7B) → JSON: parse with [jsonDecode].
///   - Anything else → YAML: parse with [loadYamlNode] to preserve spans.
///
/// Throws [OpenApiParseException] if:
///   - [bytes] is empty or contains only whitespace
///   - JSON parsing fails ([FormatException])
///   - YAML parsing fails ([YamlException])
///   - Parsed root is not a Map (malformed spec)
SniffResult sniffSpec(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const OpenApiParseException('Spec file is empty.', jsonPointer: '#');
  }

  // Find first non-whitespace byte
  final content = utf8.decode(bytes);
  final trimmed = content.trimLeft();
  if (trimmed.isEmpty) {
    throw const OpenApiParseException(
      'Spec file contains only whitespace.',
      jsonPointer: '#',
    );
  }

  if (trimmed.codeUnitAt(0) == 0x7B) {
    // JSON path
    final dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException catch (e) {
      throw OpenApiParseException(
        'Failed to parse spec as JSON: ${e.message}',
        jsonPointer: '#',
      );
    }
    if (decoded is! Map) {
      throw const OpenApiParseException(
        'Spec root must be a JSON object (map), not an array or scalar.',
        jsonPointer: '#',
      );
    }
    return JsonSniffResult(Map<String, dynamic>.from(decoded));
  } else {
    // YAML path — use loadYamlNode to preserve spans (NOT loadYaml)
    final YamlNode rootNode;
    try {
      rootNode = loadYamlNode(content);
    } on YamlException catch (e) {
      throw OpenApiParseException(
        'Failed to parse spec as YAML: ${e.message}',
        jsonPointer: '#',
      );
    }
    if (rootNode is! YamlMap) {
      throw const OpenApiParseException(
        'Spec root must be a YAML mapping (object), not a sequence or scalar.',
        jsonPointer: '#',
      );
    }
    // Build SourceMap BEFORE converting to plain map
    final sourceMap = buildSourceMap(rootNode);
    // YamlMap implements Map<dynamic, dynamic> — convert to typed Map<String, dynamic>
    final plainMap = _yamlToMap(rootNode);
    return YamlSniffResult(plainMap, sourceMap);
  }
}

/// Recursively converts a [YamlMap] or [YamlList] to plain Dart collections.
///
/// MUST be called AFTER [buildSourceMap] — this step loses all span information.
Map<String, dynamic> _yamlToMap(YamlMap yaml) {
  return {
    for (final entry in yaml.entries)
      entry.key.toString(): _yamlValue(entry.value),
  };
}

dynamic _yamlValue(dynamic value) {
  if (value is YamlMap) return _yamlToMap(value);
  if (value is YamlList) return [for (final item in value) _yamlValue(item)];
  return value; // scalar: String, int, double, bool, null
}
