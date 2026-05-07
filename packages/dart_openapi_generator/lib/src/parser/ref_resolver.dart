import '../model/openapi_parse_exception.dart';
import '../model/schema_object.dart';
import 'schema_parser.dart';
import 'source_map.dart';

/// Resolves same-file `$ref` pointers in an OpenAPI document.
///
/// Implements eager resolution: all `$ref` values in `components/schemas`
/// are resolved before [SpecParser] returns the [SpecDocument].
///
/// Uses two data structures for cycle detection:
///   - [_resolved]: memoization cache — each pointer resolved at most once.
///   - [_inProgress]: in-flight set — pointer present while being resolved.
///
/// When a pointer is found in [_inProgress], a [_CyclicRefSchema] sentinel
/// is returned immediately, breaking the cycle. Generators check for this
/// sentinel and emit `late` or nullable Dart fields for recursive types.
///
/// One instance per parse invocation. Not thread-safe; not reusable.
final class RefResolver {
  final Map<String, dynamic> _document;
  final SourceMap _sourceMap;
  late final SchemaParser _schemaParser;

  final _resolved = <String, SchemaObject>{};
  final _inProgress = <String>{};

  RefResolver(this._document, this._sourceMap);

  /// Called by [SchemaParser] after construction to wire the mutual dependency.
  void bindParser(SchemaParser parser) {
    _schemaParser = parser;
  }

  /// Resolves [ref] (a `$ref` value, e.g., `'#/components/schemas/User'`) to
  /// a [SchemaObject].
  ///
  /// Throws [OpenApiParseException] if:
  ///   - [ref] does not start with `'#/'` (external refs are unsupported in v0.1.0)
  ///   - The pointed-to location does not exist in the document
  SchemaObject resolve(String ref, String callerPointer) {
    if (!ref.startsWith('#/')) {
      throw OpenApiParseException(
        'External \$ref is not supported in v0.1.0 (planned for v0.2.x): "$ref". '
        'Only same-document references starting with "#/" are supported.',
        jsonPointer: callerPointer,
        sourceSpan: _sourceMap.spanAt(callerPointer),
      );
    }

    // Convert '#/components/schemas/Foo' → '/components/schemas/Foo'
    final pointer = ref.substring(1);

    // Memoization: already resolved → return cached result
    if (_resolved.containsKey(pointer)) {
      return _resolved[pointer]!;
    }

    // Cycle detection: currently being resolved → return sentinel
    if (_inProgress.contains(pointer)) {
      return createCyclicRef(pointer);
    }

    _inProgress.add(pointer);
    try {
      final rawSchema = _navigateTo(pointer, callerPointer);
      // Extract the component name from the pointer path (last segment)
      // e.g., '/components/schemas/User' → 'User'
      final segments = pointer.split('/');
      final componentName = segments.last;

      final schema = _schemaParser.parseWithName(
        rawSchema,
        pointer,
        componentName,
      );
      _resolved[pointer] = schema;
      return schema;
    } finally {
      _inProgress.remove(pointer);
    }
  }

  /// Navigates to [pointer] (e.g., `'/components/schemas/User'`) within [_document].
  ///
  /// Throws [OpenApiParseException] if any segment along the path is missing.
  Map<String, dynamic> _navigateTo(String pointer, String callerPointer) {
    // pointer starts with '/', split skips the empty leading segment
    final segments = pointer.split('/').skip(1).toList();
    dynamic current = _document;
    var currentPointer = '#';

    for (final segment in segments) {
      // RFC 6901: unescape '~1' → '/', '~0' → '~'
      final unescaped = segment.replaceAll('~1', '/').replaceAll('~0', '~');
      currentPointer = '$currentPointer/$segment';

      if (current is! Map) {
        throw OpenApiParseException(
          'Cannot navigate to "#$pointer": '
          '"$currentPointer" is not a map (found ${current.runtimeType}).',
          jsonPointer: callerPointer,
          sourceSpan: _sourceMap.spanAt(callerPointer),
        );
      }
      if (!current.containsKey(unescaped)) {
        throw OpenApiParseException(
          '\$ref target not found: "#$pointer". '
          'The path "$currentPointer" does not exist in this document.',
          jsonPointer: callerPointer,
          sourceSpan: _sourceMap.spanAt(callerPointer),
        );
      }
      current = current[unescaped];
    }

    if (current is! Map) {
      throw OpenApiParseException(
        '\$ref target "#$pointer" must be a schema object (map), '
        'but found ${current.runtimeType}.',
        jsonPointer: callerPointer,
        sourceSpan: _sourceMap.spanAt(callerPointer),
      );
    }
    return Map<String, dynamic>.from(current);
  }
}
