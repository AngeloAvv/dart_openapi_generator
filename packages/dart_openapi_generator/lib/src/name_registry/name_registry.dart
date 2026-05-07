import '../model/openapi_parse_exception.dart';
import '../model/schema_object.dart';
import '../model/spec_document.dart';
import 'keyword_escaper.dart';
import 'name_converter.dart';

/// Immutable registry mapping OpenAPI spec names to valid Dart identifiers.
///
/// Built once by [buildNameRegistry] from a [SpecDocument]. Never mutated
/// after construction. All generators query this registry; never re-derive
/// names independently.
///
/// Internal state:
///   - [_classNames]: spec component name → Dart class name
///     Example: `{'User' → 'User', 'payment_method' → 'PaymentMethod'}`
///   - [_fieldNames]: `'SchemaName/propertyName'` → Dart field name
///     Example: `{'User/created_at' → 'createdAt', 'User/class' → 'class_'}`
///
/// Exposed only via [dartClassName] and [dartFieldName].
final class NameRegistry {
  final Map<String, String> _classNames;
  final Map<String, String> _fieldNames;

  NameRegistry._internal(this._classNames, this._fieldNames);

  /// Returns the Dart class name for the spec component named [specName].
  ///
  /// Throws [StateError] if [specName] was not registered — this indicates a
  /// programming error (callers should only request names that exist in the spec).
  String dartClassName(String specName) =>
      _classNames[specName] ??
      (throw StateError(
        'NameRegistry has no entry for spec name "$specName". '
        'Registered names: ${_classNames.keys.join(", ")}',
      ));

  /// Returns the Dart field name for [propertyName] on schema [schemaName].
  ///
  /// Key format: `'$schemaName/$propertyName'` (slash separator).
  ///
  /// Throws [StateError] if the combination was not registered.
  String dartFieldName(String schemaName, String propertyName) {
    final key = '$schemaName/$propertyName';
    return _fieldNames[key] ??
        (throw StateError(
          'NameRegistry has no field entry for "$key". '
          'Ensure "$schemaName" was registered and "$propertyName" is a property.',
        ));
  }
}

/// Builds an immutable [NameRegistry] from [document].
///
/// Two-pass build:
///   Pass 1 — Collect all schema names:
///     - Component schemas: use the component map key as the spec name.
///     - Inline request body schemas from operations: name = `<OperationId>Request`
///       or `<Method><PathSegments>Request` fallback.
///     - Inline response schemas from operations: name = `<OperationId>Response`
///       or `<Method><PathSegments>Response` fallback.
///     - Property names within each ObjectSchema.
///   Pass 2 — Convert + validate:
///     - Apply [toPascalCase] + [escapeKeyword] to class names.
///     - Apply [toLowerCamelCase] + [escapeKeyword] to field names.
///     - Detect duplicates across all generated class names.
///
/// Throws [OpenApiParseException] if duplicate generated names are detected.
NameRegistry buildNameRegistry(SpecDocument document) {
  // --- Pass 1: Collect ---
  // Map from spec name → first-seen spec location (for duplicate error messages)
  final classSpecNames = <String, String>{}; // specName → source description

  // Collect component schema names
  for (final entry in document.schemas.entries) {
    classSpecNames[entry.key] = '#/components/schemas/${entry.key}';
  }

  // Collect inline schema names from operations
  for (final op in document.operations) {
    final base = _operationBaseName(op);
    if (base.isEmpty) {
      throw OpenApiParseException(
        'Could not derive a non-empty base name for operation '
        '${op.method.toUpperCase()} ${op.path}. '
        'Provide a non-empty operationId or a non-empty path.',
        jsonPointer: '${op.path}:${op.method}',
      );
    }
    if (op.requestBody?.jsonSchema != null) {
      final name = '${base}Request';
      classSpecNames.putIfAbsent(
        name,
        () => '${op.path}:${op.method}:requestBody',
      );
    }
    // Collect response schemas (200/201 typically have bodies)
    for (final response in op.responses.values) {
      if (response.jsonSchema != null) {
        final suffix = _responseSuffix(response.statusCode);
        final name = '$base$suffix';
        classSpecNames.putIfAbsent(
          name,
          () => '${op.path}:${op.method}:responses:${response.statusCode}',
        );
      }
    }
  }

  // Collect property names per schema
  // Key: 'specName/propertyName' → (fieldSpecName, source description)
  final fieldSpecNames = <String, (String, String)>{};

  void collectProperties(String schemaName, SchemaObject schema) {
    if (schema is ObjectSchema) {
      for (final prop in schema.properties) {
        final key = '$schemaName/${prop.specName}';
        fieldSpecNames[key] = (
          prop.specName,
          '#/components/schemas/$schemaName/properties/${prop.specName}',
        );
      }
    } else if (schema is AllOfSchema) {
      // allOf: register all member ObjectSchema properties under the allOf schema name.
      // _emitAllOfClass creates a synthetic ObjectSchema with specName = schemaName,
      // so field lookups will be '$schemaName/$propName'.
      for (final member in schema.schemas) {
        if (member is ObjectSchema) {
          for (final prop in member.properties) {
            final key = '$schemaName/${prop.specName}';
            fieldSpecNames.putIfAbsent(
              key,
              () => (
                prop.specName,
                '#/components/schemas/$schemaName/allOf/properties/${prop.specName}',
              ),
            );
          }
        }
      }
    } else if (schema is OneOfSchema) {
      // Register field names for embedded variant ObjectSchemas so that
      // _resolveProperties can call dartFieldName for variants that are NOT
      // registered as top-level document.schemas entries.
      for (var i = 0; i < schema.variants.length; i++) {
        final variant = schema.variants[i];
        if (variant is ObjectSchema) {
          // Use the variant's named identity if available; otherwise synthesise
          // a name so that anonymous inline variants are not silently skipped.
          final variantName =
              (variant.name != null && variant.name!.isNotEmpty)
                  ? variant.name!
                  : '${schemaName}Variant$i';
          for (final prop in variant.properties) {
            final key = '$variantName/${prop.specName}';
            fieldSpecNames.putIfAbsent(
              key,
              () => (
                prop.specName,
                '#/components/schemas/$schemaName/oneOf/$variantName/properties/${prop.specName}',
              ),
            );
          }
        }
      }
    }
  }

  for (final entry in document.schemas.entries) {
    collectProperties(entry.key, entry.value);
  }

  // --- Pass 2: Convert, escape, detect duplicates ---
  // Class names: spec name → Dart class name
  final classNames = <String, String>{};
  // Reverse map for duplicate detection: generated Dart name → first spec source
  final generatedClassNames = <String, String>{}; // dartName → specName

  for (final entry in classSpecNames.entries) {
    final specName = entry.key;
    final source = entry.value;
    final dartName = escapeKeyword(toPascalCase(specName));

    if (dartName.isEmpty || !RegExp(r'^[a-zA-Z_]').hasMatch(dartName)) {
      throw OpenApiParseException(
        'Spec component name "$specName" produces an invalid Dart class name '
        '"$dartName". Class names must be non-empty and start with a letter or '
        'underscore. Rename the schema in the spec.',
        jsonPointer: source,
      );
    }

    if (generatedClassNames.containsKey(dartName)) {
      final firstSource = generatedClassNames[dartName]!;
      throw OpenApiParseException(
        'Duplicate generated Dart class name "$dartName" produced by two spec locations: '
        '"$firstSource" and "$source". Rename one of the schemas or operations to avoid '
        'the collision.',
        jsonPointer: source,
      );
    }
    generatedClassNames[dartName] = source;
    classNames[specName] = dartName;
  }

  // Field names: 'specName/propName' → Dart field name
  final fieldNames = <String, String>{};
  for (final entry in fieldSpecNames.entries) {
    final key = entry.key;
    final (propName, _) = entry.value;
    fieldNames[key] = escapeKeyword(toLowerCamelCase(propName));
  }

  return NameRegistry._internal(classNames, fieldNames);
}

/// Derives the base name for an operation's inline request/response schemas.
///
/// Uses `operationId` if present; otherwise builds from HTTP method + path segments.
/// Path segments have leading slashes removed and `{param}` braces removed.
///
/// Examples:
///   operationId = 'getUser'   → 'GetUser'
///   method = 'get', path = '/users/{id}' → 'GetUsersId'
String _operationBaseName(OperationItem op) {
  if (op.operationId != null && op.operationId!.isNotEmpty) {
    return toPascalCase(op.operationId!);
  }
  // Fallback: METHOD + path segments (remove {braces} and leading slashes)
  final methodPart = toPascalCase(op.method);
  final pathParts =
      op.path
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
String _responseSuffix(String statusCode) {
  if (statusCode == '200' || statusCode == '201') return 'Response';
  if (statusCode == 'default') return 'DefaultResponse';
  return 'Status${statusCode}Response';
}
