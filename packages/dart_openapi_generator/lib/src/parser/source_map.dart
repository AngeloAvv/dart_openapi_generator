import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

/// A mapping from JSON Pointer strings to [SourceSpan]s.
///
/// Built during the initial YAML parse pass by walking the [YamlNode] tree
/// before any conversion to plain Dart maps. For JSON input where spans are
/// unavailable, construct with [SourceMap.empty].
///
/// Keys follow RFC 6901 JSON Pointer notation:
///   - Root document → `'#'`
///   - `components/schemas/User` → `'#/components/schemas/User'`
///   - Property named `foo/bar` → `'#/components/schemas/Obj/properties/foo~1bar'`
///
/// [spanAt] returns `null` for unknown pointers — safe to call for JSON input.
final class SourceMap {
  final Map<String, SourceSpan> _spans;

  const SourceMap(this._spans);

  /// Creates an empty [SourceMap] for JSON input (no span information available).
  const SourceMap.empty() : _spans = const {};

  /// Returns the [SourceSpan] recorded for [jsonPointer], or `null` if absent.
  SourceSpan? spanAt(String jsonPointer) => _spans[jsonPointer];
}

/// Builds a [SourceMap] by recursively walking [root] (the result of
/// `loadYamlNode()`).
///
/// Must be called BEFORE converting the [YamlNode] tree to plain Dart maps,
/// because span information is irretrievable after conversion.
///
/// Uses RFC 6901 escaping for key segments:
///   `'~'` → `'~0'`, `'/'` → `'~1'`
SourceMap buildSourceMap(YamlNode root) {
  final spans = <String, SourceSpan>{};
  _walk(root, '#', spans);
  return SourceMap(spans);
}

void _walk(YamlNode node, String pointer, Map<String, SourceSpan> spans) {
  spans[pointer] = node.span;
  if (node is YamlMap) {
    for (final entry in node.nodes.entries) {
      // Keys in YamlMap.nodes are YamlNodes (YamlScalar); .value gives the Dart key.
      final keyNode = entry.key as YamlNode;
      final key = keyNode.value.toString();
      // RFC 6901: escape '~' first (before '/') to avoid double-escaping
      final escaped = key.replaceAll('~', '~0').replaceAll('/', '~1');
      _walk(entry.value, '$pointer/$escaped', spans);
    }
  } else if (node is YamlList) {
    for (var i = 0; i < node.nodes.length; i++) {
      _walk(node.nodes[i], '$pointer/$i', spans);
    }
  }
  // YamlScalar: leaf node — span already recorded above; no children to recurse.
}
