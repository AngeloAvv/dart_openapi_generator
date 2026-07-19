import '../model/schema_object.dart';
import '../model/spec_document.dart';
import 'operation_naming.dart';
import 'operation_parser.dart';
import 'ref_resolver.dart';
import 'schema_parser.dart';
import 'source_map.dart';
import 'version_validator.dart';

/// Top-level orchestrator that drives the full parse pipeline from raw spec
/// map → [SpecDocument].
///
/// Pipeline stages:
///   1. Extract top-level metadata (title, version, spec version, baseUrl).
///   2. Build [RefResolver] + [SchemaParser] + [OperationParser].
///   3. Resolve component schemas → [Map<String, SchemaObject>].
///   4. Parse operations (paths → [OperationItem] list).
///   5. Parse security schemes → [Map<String, SecurityScheme>].
///   6. Assemble [SpecDocument].
///
/// Stateless across parses — create a new instance per parse or reuse freely.
final class OpenApiParser {
  const OpenApiParser();

  /// Parses a raw spec map (produced by [sniffSpec]) into a [SpecDocument].
  ///
  /// [rawMap] is the plain `Map<String, dynamic>` of the spec root.
  /// [sourceMap] is used to attach source locations to thrown exceptions.
  SpecDocument parse(Map<String, dynamic> rawMap, SourceMap sourceMap) {
    // --- (0) Validate spec version before doing anything else ---
    validateVersion(rawMap['openapi'] as String?, sourceMap);

    // --- (1) Extract top-level metadata ---
    final specVersion = rawMap['openapi'] as String? ?? '';
    final info = rawMap['info'] as Map? ?? {};
    final title = info['title'] as String? ?? '';

    // servers[0].url → baseUrl (empty when no servers block)
    final serversRaw = rawMap['servers'] as List?;
    final baseUrl =
        serversRaw != null && serversRaw.isNotEmpty
            ? ((serversRaw.first as Map?)?['url'] as String? ?? '')
            : '';

    // --- (2) Build parser stack ---
    final refResolver = RefResolver(rawMap, sourceMap);
    final schemaParser = SchemaParser(sourceMap, refResolver);
    final operationParser = OperationParser(sourceMap, schemaParser);

    // --- (3) Resolve component schemas ---
    final schemas = <String, dynamic>{};
    final componentsRaw = rawMap['components'] as Map? ?? {};
    final schemasRaw = componentsRaw['schemas'] as Map?;
    if (schemasRaw != null) {
      schemasRaw.forEach((key, value) {
        schemas[key.toString()] = value;
      });
    }

    // Eagerly resolve all component schemas so cycle detection runs now.
    final resolvedSchemas = <String, SchemaObject>{};
    for (final entry in schemas.entries) {
      final pointer =
          '#/components/schemas/${_encodePointerSegment(entry.key)}';
      if (entry.value is Map) {
        resolvedSchemas[entry.key] = schemaParser.parseWithName(
          Map<String, dynamic>.from(entry.value as Map),
          pointer,
          entry.key,
        );
      }
    }

    // --- (4) Parse operations ---
    final pathsRaw = rawMap['paths'] as Map? ?? {};
    final operations = operationParser.parseOperations(
      Map<String, dynamic>.from(pathsRaw),
      specVersion,
    );

    // Register inline (non-$ref) request/response body schemas so
    // ModelGenerator actually emits a file for them. Only "nameable" kinds
    // (Object/Enum/OneOf/AllOf) need a wrapper class — see [NameRegistry],
    // which registers class names for this exact same set of schemas under
    // the exact same computed names (shared via operation_naming.dart).
    void registerInlineBodySchema(String computedName, SchemaObject schema) {
      resolvedSchemas.putIfAbsent(computedName, () => schema);
    }

    for (final op in operations) {
      final base = operationBaseName(op.operationId, op.method, op.path);
      final requestSchema = op.requestBody?.jsonSchema;
      if (requestSchema != null && _isNameableInlineSchema(requestSchema)) {
        registerInlineBodySchema('${base}Request', requestSchema);
      }
      for (final response in op.responses.values) {
        final responseSchema = response.jsonSchema;
        if (responseSchema != null && _isNameableInlineSchema(responseSchema)) {
          registerInlineBodySchema(
            '$base${responseSuffix(response.statusCode)}',
            responseSchema,
          );
        }
      }
    }

    // --- (5) Parse security schemes ---
    final securitySchemesMap = <String, SecurityScheme>{};
    final schemesRaw = componentsRaw['securitySchemes'] as Map? ?? {};
    schemesRaw.forEach((key, value) {
      if (value is! Map) return;
      final name = key.toString();
      final schemeMap = Map<String, dynamic>.from(value);
      securitySchemesMap[name] = SecurityScheme(
        name: name,
        type: schemeMap['type'] as String? ?? '',
        scheme: schemeMap['scheme'] as String?,
        bearerFormat: schemeMap['bearerFormat'] as String?,
        location: schemeMap['in'] as String?,
        paramName: schemeMap['name'] as String?,
      );
    });

    // --- (6) Assemble ---
    return SpecDocument(
      specVersion: specVersion,
      title: title,
      baseUrl: baseUrl,
      schemas: resolvedSchemas,
      operations: operations,
      securitySchemes: securitySchemesMap,
    );
  }

  String _encodePointerSegment(String segment) =>
      segment.replaceAll('~', '~0').replaceAll('/', '~1');
}

/// Returns `true` for schemas that need their own generated class and are
/// truly inline (not a `$ref` to an existing named component — those already
/// have a name and are already registered under it).
bool _isNameableInlineSchema(SchemaObject schema) =>
    schema.name == null &&
    (schema is ObjectSchema ||
        schema is EnumSchema ||
        schema is OneOfSchema ||
        schema is AllOfSchema);

/// Wrapper that surfaces a parsed [SpecDocument] together with its
/// [SourceMap] for downstream phases that need source locations.
final class ParseResult {
  final SpecDocument document;
  final SourceMap sourceMap;

  const ParseResult(this.document, this.sourceMap);
}

/// Convenience top-level function used by [OpenApiBuilder] to run the full
/// pipeline and return a [ParseResult].
///
/// Throws [OpenApiParseException] on any validation or parse failure.
ParseResult parseSpec(Map<String, dynamic> rawMap, SourceMap sourceMap) {
  final parser = const OpenApiParser();
  final document = parser.parse(rawMap, sourceMap);
  return ParseResult(document, sourceMap);
}
