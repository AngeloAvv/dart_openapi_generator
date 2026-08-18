import '../model/openapi_parse_exception.dart';
import '../model/schema_object.dart';
import 'ref_resolver.dart';
import 'source_map.dart';

/// Parses raw [Map<String, dynamic>] spec maps into [SchemaObject] instances.
///
/// Implements the discrimination rules from OpenAPI 3.x § Schema Object:
///   1. `$ref` key → delegate to [RefResolver] (FIRST; overrides all sibling keys in 3.0)
///   2. `anyOf` key → throw [OpenApiParseException] (unsupported; deferred to v0.2.x)
///   3. `allOf` key → [AllOfSchema]
///   4. `oneOf` key → [OneOfSchema] (with optional discriminator validation)
///   5. `enum` key → [EnumSchema]
///   6. `type == 'null'` → [NullSchema] (3.1+ only)
///   7. `type == 'array'` or `items` key → [ArraySchema]
///   8. `type == 'object'` or `properties` key or type absent (not enum) → [ObjectSchema]
///   9. Primitive types (`string`, `integer`, `number`, `boolean`) → [PrimitiveSchema]
///
/// Nullable normalization:
///   - 3.0: `nullable: true` → `isNullable: true`
///   - 3.1/3.2: `type: [T, 'null']` → `isNullable: true`, extract T as effective type
///   - Both present simultaneously → throw [OpenApiParseException]
///
/// One instance per parse invocation. Holds a [RefResolver] for `$ref` delegation.
final class SchemaParser {
  final SourceMap _sourceMap;
  final RefResolver _refResolver;

  SchemaParser(this._sourceMap, this._refResolver) {
    // Wire the mutual dependency
    _refResolver.bindParser(this);
  }

  /// Parses [raw] at [jsonPointer] into a [SchemaObject].
  ///
  /// [name] is optional component name when resolved from `$ref`;
  /// pass `null` for inline schemas.
  SchemaObject parse(
    Map<String, dynamic> raw,
    String jsonPointer, {
    String? name,
  }) {
    return parseWithName(raw, jsonPointer, name);
  }

  /// Internal entry point used by [RefResolver] to pass the resolved component name.
  SchemaObject parseWithName(
    Map<String, dynamic> raw,
    String jsonPointer,
    String? name,
  ) {
    // 1. $ref takes priority over all sibling keys (OpenAPI 3.0 rule; Pitfall 3)
    final ref = raw[r'$ref'];
    if (ref is String) {
      return _refResolver.resolve(ref, jsonPointer);
    }

    // 2. anyOf → reject (unsupported in v0.1.0)
    if (raw.containsKey('anyOf')) {
      throw OpenApiParseException(
        '"anyOf" is not supported in v0.1.0 (planned for v0.2.x). '
        'Use "oneOf" with a discriminator instead.',
        jsonPointer: '$jsonPointer/anyOf',
        sourceSpan: _sourceMap.spanAt('$jsonPointer/anyOf'),
      );
    }

    // 3. allOf → AllOfSchema
    if (raw.containsKey('allOf')) {
      return _parseAllOf(raw, jsonPointer, name);
    }

    // 4. oneOf → OneOfSchema
    if (raw.containsKey('oneOf')) {
      return _parseOneOf(raw, jsonPointer, name);
    }

    final type = raw['type'];

    // Handle 3.1/3.2 type arrays: type: [T, 'null'] — extract effective type for dispatch
    // NOTE: normalise BEFORE the enum branch so that nullable 3.1 enums
    // (e.g. {type: ['string','null'], enum: [...]}) are detected correctly.
    String? effectiveType;
    bool isNullable;
    if (type is List) {
      final normalized = _normalizeTypeArray(type, raw, jsonPointer);
      effectiveType = normalized.$1;
      isNullable = normalized.$2;
    } else {
      effectiveType = type as String?;
      isNullable = raw['nullable'] == true;
    }

    // 5. enum → EnumSchema (check BEFORE type check; enum coexists with type:string)
    if (raw.containsKey('enum')) {
      return _parseEnum(raw, jsonPointer, name, isNullable);
    }

    // Reject mixed nullable styles (redundant check for non-List case caught in _normalizeTypeArray)
    if (raw['nullable'] == true && type is List && (type).contains('null')) {
      throw OpenApiParseException(
        'Mixed nullable styles detected: both "nullable: true" (OpenAPI 3.0) and '
        '"type: [T, null]" (OpenAPI 3.1) are present on the same schema. '
        'Use one style consistently.',
        jsonPointer: jsonPointer,
        sourceSpan: _sourceMap.spanAt(jsonPointer),
      );
    }

    // 6. type: null (3.1+ standalone null schema) → NullSchema
    if (effectiveType == 'null') {
      return NullSchema(name: name, description: raw['description'] as String?);
    }

    // 7. type: array OR items key present → ArraySchema
    if (effectiveType == 'array' || raw.containsKey('items')) {
      return _parseArray(raw, jsonPointer, name, isNullable);
    }

    // 8. type: object OR properties present OR no type (implicit object) → ObjectSchema
    // IMPORTANT: type==null with no enum/array/oneOf/allOf = implicit object (Pitfall 6)
    if (effectiveType == 'object' ||
        raw.containsKey('properties') ||
        (effectiveType == null &&
            !raw.containsKey('enum') &&
            !raw.containsKey('oneOf') &&
            !raw.containsKey('allOf'))) {
      return _parseObject(raw, jsonPointer, name, isNullable);
    }

    // 9. Primitive types
    const primitives = {'string', 'integer', 'number', 'boolean'};
    if (effectiveType != null && primitives.contains(effectiveType)) {
      return PrimitiveSchema(
        name: name,
        description: raw['description'] as String?,
        primitiveType: effectiveType,
        format: raw['format'] as String?,
        isNullable: isNullable,
      );
    }

    throw OpenApiParseException(
      'Unknown or unsupported schema type: "$effectiveType". '
      'Expected one of: object, array, string, integer, number, boolean, null, '
      'or a composition keyword (allOf, oneOf).',
      jsonPointer: '$jsonPointer/type',
      sourceSpan: _sourceMap.spanAt('$jsonPointer/type'),
    );
  }

  // --- Private helpers ---

  AllOfSchema _parseAllOf(
    Map<String, dynamic> raw,
    String pointer,
    String? name,
  ) {
    final allOfList = raw['allOf'] as List?;
    if (allOfList == null || allOfList.isEmpty) {
      throw OpenApiParseException(
        '"allOf" must be a non-empty list of schemas.',
        jsonPointer: '$pointer/allOf',
        sourceSpan: _sourceMap.spanAt('$pointer/allOf'),
      );
    }
    final schemas = <SchemaObject>[];
    for (var i = 0; i < allOfList.length; i++) {
      schemas.add(
        parseWithName(
          Map<String, dynamic>.from(allOfList[i] as Map),
          '$pointer/allOf/$i',
          null,
        ),
      );
    }
    // OpenAPI 3.0 nullable $ref wrapper: { type: object, allOf: [{$ref}], nullable: true }
    // When allOf has exactly one entry that resolved to a named schema, propagate
    // the resolved name and outer nullable flag so _dartType/fromJson/toJson
    // can emit the correct class name instead of 'dynamic'.
    if (schemas.length == 1 && schemas.first.name != null) {
      return AllOfSchema(
        name: schemas.first.name,
        description: raw['description'] as String?,
        schemas: schemas,
        isNullable: raw['nullable'] == true,
      );
    }
    return AllOfSchema(
      name: name,
      description: raw['description'] as String?,
      schemas: schemas,
      isNullable: raw['nullable'] == true,
    );
  }

  SchemaObject _parseOneOf(
    Map<String, dynamic> raw,
    String pointer,
    String? name,
  ) {
    final oneOfList = raw['oneOf'] as List?;
    if (oneOfList == null || oneOfList.isEmpty) {
      throw OpenApiParseException(
        '"oneOf" must be a non-empty list of schemas.',
        jsonPointer: '$pointer/oneOf',
        sourceSpan: _sourceMap.spanAt('$pointer/oneOf'),
      );
    }

    final variants = <SchemaObject>[];
    for (var i = 0; i < oneOfList.length; i++) {
      variants.add(
        parseWithName(
          Map<String, dynamic>.from(oneOfList[i] as Map),
          '$pointer/oneOf/$i',
          null,
        ),
      );
    }

    // A single-branch oneOf in an inline position (a parameter, a body) is just
    // that branch with extra ceremony: collapse it instead of generating a
    // sealed wrapper with one case. Named schemas are left alone — collapsing
    // '#/components/schemas/Foo: {oneOf: [Bar]}' would make Foo disappear.
    if (variants.length == 1 && name == null && raw['discriminator'] == null) {
      return variants.first;
    }

    // Discriminator (optional)
    final discriminatorMap = raw['discriminator'] as Map?;
    String? discriminatorPropertyName;
    Map<String, String>? discriminatorMapping;

    if (discriminatorMap != null) {
      discriminatorPropertyName = discriminatorMap['propertyName'] as String?;
      if (discriminatorPropertyName == null) {
        throw OpenApiParseException(
          '"discriminator" object is missing required "propertyName" field.',
          jsonPointer: '$pointer/discriminator',
          sourceSpan: _sourceMap.spanAt('$pointer/discriminator'),
        );
      }
      final rawMapping = discriminatorMap['mapping'] as Map?;
      if (rawMapping != null) {
        discriminatorMapping = Map<String, String>.from(
          rawMapping.map((k, v) => MapEntry(k.toString(), v.toString())),
        );
      }

      // Validate discriminator: every resolved variant must have the property
      // Run AFTER resolution (variants list is now resolved) — Pitfall 7
      _validateDiscriminator(variants, discriminatorPropertyName, pointer);
    }

    return OneOfSchema(
      name: name,
      description: raw['description'] as String?,
      variants: variants,
      discriminatorPropertyName: discriminatorPropertyName,
      discriminatorMapping: discriminatorMapping,
    );
  }

  /// Validates that [discriminatorProperty] exists on every resolved variant.
  ///
  /// Must be called AFTER $ref resolution — checking pre-resolution maps produces
  /// false positives (Pitfall 7).
  void _validateDiscriminator(
    List<SchemaObject> variants,
    String discriminatorProperty,
    String pointer,
  ) {
    for (var i = 0; i < variants.length; i++) {
      final variant = variants[i];
      if (!_hasDiscriminatorProperty(variant, discriminatorProperty)) {
        throw OpenApiParseException(
          'oneOf variant at index $i is missing the discriminator property '
          '"$discriminatorProperty". Every variant must declare this property.',
          jsonPointer: '$pointer/oneOf/$i',
          sourceSpan: _sourceMap.spanAt('$pointer/oneOf/$i'),
        );
      }
    }
  }

  /// Returns `true` if [schema] declares [property] directly or transitively
  /// through nested `allOf` members (recursive).
  bool _hasDiscriminatorProperty(SchemaObject schema, String property) {
    return switch (schema) {
      ObjectSchema() => schema.properties.any((p) => p.specName == property),
      AllOfSchema() => schema.schemas.any(
        (s) => _hasDiscriminatorProperty(s, property),
      ),
      _ => false,
    };
  }

  EnumSchema _parseEnum(
    Map<String, dynamic> raw,
    String pointer,
    String? name,
    bool isNullable,
  ) {
    final values = (raw['enum'] as List? ?? []).cast<dynamic>();
    // For 3.1 type arrays (e.g. ['string','null']), the effective type has
    // already been extracted; fall back to the raw string type or 'string'.
    final rawType = raw['type'];
    final enumType =
        rawType is String ? rawType : (rawType is List ? null : null);
    return EnumSchema(
      name: name,
      description: raw['description'] as String?,
      enumType: enumType ?? 'string',
      values: values,
      isNullable: isNullable,
    );
  }

  ArraySchema _parseArray(
    Map<String, dynamic> raw,
    String pointer,
    String? name,
    bool isNullable,
  ) {
    final itemsRaw = raw['items'];
    if (itemsRaw == null) {
      throw OpenApiParseException(
        'Array schema is missing required "items" field.',
        jsonPointer: '$pointer/items',
        sourceSpan: _sourceMap.spanAt('$pointer/items'),
      );
    }
    final items = parseWithName(
      Map<String, dynamic>.from(itemsRaw as Map),
      '$pointer/items',
      null,
    );
    return ArraySchema(
      name: name,
      description: raw['description'] as String?,
      items: items,
      isNullable: isNullable,
    );
  }

  ObjectSchema _parseObject(
    Map<String, dynamic> raw,
    String pointer,
    String? name,
    bool isNullable,
  ) {
    // Validate name is not digit-leading (PARSE-10)
    if (name != null && RegExp(r'^\d').hasMatch(name)) {
      throw OpenApiParseException(
        'Schema name "$name" starts with a digit, which is not a valid Dart identifier. '
        'Rename the schema in your OpenAPI spec '
        '(e.g., "${name}Schema" or "The$name").',
        jsonPointer: pointer,
        sourceSpan: _sourceMap.spanAt(pointer),
      );
    }

    final rawProperties = raw['properties'] as Map?;
    final requiredList = (raw['required'] as List? ?? []).cast<String>();
    final properties = <SchemaProperty>[];

    if (rawProperties != null) {
      rawProperties.forEach((key, value) {
        final propName = key.toString();
        final propPointer = '$pointer/properties/$propName';
        final propSchema = parseWithName(
          Map<String, dynamic>.from(value as Map),
          propPointer,
          null,
        );
        properties.add(
          SchemaProperty(
            specName: propName,
            schema: propSchema,
            isRequired: requiredList.contains(propName),
          ),
        );
      });
    }

    // additionalProperties: can be bool or schema map (OpenAPI 3.x §4.7.24)
    Object? additionalProperties;
    final rawAdditional = raw['additionalProperties'];
    if (rawAdditional is bool) {
      additionalProperties = rawAdditional;
    } else if (rawAdditional is Map) {
      additionalProperties = parseWithName(
        Map<String, dynamic>.from(rawAdditional),
        '$pointer/additionalProperties',
        null,
      );
    }

    return ObjectSchema(
      name: name,
      description: raw['description'] as String?,
      properties: properties,
      required: requiredList,
      additionalProperties: additionalProperties,
      isNullable: isNullable,
    );
  }

  /// Normalizes a 3.1/3.2 type array like `['string', 'null']` to
  /// `('string', true)` (effectiveType, isNullable).
  ///
  /// Throws if mixed styles (nullable:true + type array containing null) detected.
  (String?, bool) _normalizeTypeArray(
    List<dynamic> typeArray,
    Map<String, dynamic> raw,
    String pointer,
  ) {
    final hasNullableTrue = raw['nullable'] == true;
    final hasTypeNull = typeArray.contains('null');

    if (hasNullableTrue && hasTypeNull) {
      throw OpenApiParseException(
        'Mixed nullable styles: both "nullable: true" (OpenAPI 3.0) and '
        '"type: [T, null]" (OpenAPI 3.1) are present. Use one style consistently.',
        jsonPointer: pointer,
        sourceSpan: _sourceMap.spanAt(pointer),
      );
    }

    if (!hasTypeNull) {
      // Type array without null (unusual but valid) — use first type
      return (typeArray.isNotEmpty ? typeArray.first as String? : null, false);
    }

    final nonNullTypes = typeArray.where((t) => t != 'null').toList();
    final effective =
        nonNullTypes.length == 1
            ? nonNullTypes.first as String?
            : (nonNullTypes.isEmpty ? null : 'object');
    return (effective, true);
  }
}
