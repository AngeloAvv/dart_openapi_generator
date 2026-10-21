import '../model/media_type.dart';
import '../model/schema_object.dart';
import '../model/spec_document.dart';
import '../name_registry/name_converter.dart';

/// Derives the base name for an operation's inline request/response schemas.
///
/// Uses `operationId` if present; otherwise builds from HTTP method + path segments.
/// Path segments have leading slashes removed and `{param}` braces removed.
///
/// Examples:
///   operationId = 'getUser'   → 'GetUser'
///   method = 'get', path = '/users/{id}' → 'GetUsersId'
///
/// Shared by [buildNameRegistry] (name_registry.dart) and [OpenApiParser]
/// (openapi_parser.dart) so both agree on exactly the same computed name for
/// a given operation's inline body schema.
String operationBaseName(String? operationId, String method, String path) {
  if (operationId != null && operationId.isNotEmpty) {
    return toPascalCase(operationId);
  }
  final methodPart = toPascalCase(method);
  final pathParts =
      path
          .split('/')
          .where((s) => s.isNotEmpty)
          .map((s) => s.replaceAll(RegExp(r'[{}]'), ''))
          .where((s) => s.isNotEmpty)
          .map(toPascalCase)
          .join();
  return '$methodPart$pathParts';
}

/// Returns a human-readable suffix for a response schema name.
///
/// - `'200'`, `'201'` → `'Response'`
/// - `'default'`      → `'DefaultResponse'`
/// - Other numeric codes → `'Status${code}Response'` (prefixed to avoid
///   digit-leading Dart identifiers when the operation base name is empty)
String responseSuffix(String statusCode) {
  if (statusCode == '200' || statusCode == '201') return 'Response';
  if (statusCode == 'default') return 'DefaultResponse';
  return 'Status${statusCode}Response';
}

/// Spec name of the model the request body of [op] is typed with: the
/// component name of a `$ref` schema, `<Base>Request` for an inline schema
/// that gets a class of its own, null otherwise (no body, an array or a
/// primitive, or a media type the generator does not type).
String? requestBodySchemaName(OperationItem op) {
  final schema = op.requestBody?.schema;
  if (schema == null) return null;
  if (schema.name != null) return schema.name;
  final nameable =
      schema is ObjectSchema ||
      schema is EnumSchema ||
      schema is OneOfSchema ||
      schema is AllOfSchema;
  if (!nameable) return null;
  return '${operationBaseName(op.operationId, op.method, op.path)}Request';
}

/// Spec names of the models sent as a `multipart/form-data` body by at least
/// one operation of [document].
///
/// Their binary properties (`format: binary`, or a 3.1 `contentMediaType`)
/// are generated as Dio `MultipartFile`s: only a multipart body can carry a
/// file, so models never used that way keep the plain `String` they always
/// had.
Set<String> multipartBodySchemaNames(SpecDocument document) => {
  for (final op in document.operations)
    if (op.requestBody?.kind == MediaTypeKind.multipart)
      if (requestBodySchemaName(op) case final name?) name,
};

/// The operations of [document] that use one of [names] other than as a
/// `multipart/form-data` body, keyed by name: in a JSON or url-encoded request
/// body or in a JSON response, directly or nested in another schema, or
/// nested in a multipart body (where it is sent as a JSON part).
///
/// A model sent as a multipart body has `MultipartFile` fields, which no JSON
/// payload can carry: every use listed here breaks at runtime.
Map<String, List<String>> nonMultipartUses(
  SpecDocument document,
  Set<String> names,
) {
  final uses = <String, List<String>>{};
  for (final op in document.operations) {
    final label = op.operationId ?? '${op.method.toUpperCase()} ${op.path}';
    final found = <String>{};
    final visited = <String>{};
    void walk(SchemaObject schema) {
      final name = schema.name;
      if (name != null) {
        if (names.contains(name)) found.add(name);
        if (!visited.add(name)) return;
      }
      switch (schema) {
        case ObjectSchema(:final properties, :final additionalProperties):
          for (final property in properties) {
            walk(property.schema);
          }
          if (additionalProperties is SchemaObject) walk(additionalProperties);
        case ArraySchema(:final items):
          walk(items);
        case AllOfSchema(:final schemas):
          schemas.forEach(walk);
        case OneOfSchema(:final variants):
          variants.forEach(walk);
        default:
      }
    }

    final body = op.requestBody?.schema;
    if (body != null) {
      if (op.requestBody!.kind == MediaTypeKind.multipart) {
        // The body itself is the multipart use; what it nests is not.
        switch (body) {
          case ObjectSchema(:final properties):
            for (final property in properties) {
              walk(property.schema);
            }
          case AllOfSchema(:final schemas):
            for (final member in schemas.whereType<ObjectSchema>()) {
              for (final property in member.properties) {
                walk(property.schema);
              }
            }
          default:
        }
      } else {
        walk(body);
      }
    }
    for (final response in op.responses.values) {
      if (response.schema case final schema?) walk(schema);
    }
    for (final name in found) {
      uses.putIfAbsent(name, () => []).add(label);
    }
  }
  return uses;
}
