import 'package:meta/meta.dart';

/// Base sealed class for all OpenAPI schema representations.
///
/// Public subtypes: [ObjectSchema], [EnumSchema], [PrimitiveSchema],
/// [ArraySchema], [AllOfSchema], [OneOfSchema], [NullSchema].
///
/// Private sentinel: [_CyclicRefSchema] — emitted by [RefResolver]
/// when a `$ref` cycle is detected. Generators must check for this with
/// [isCyclicRef] and emit `late` or nullable Dart fields.
///
/// [name] holds the original component name when resolved from `$ref`
/// (e.g., `$ref: '#/components/schemas/Foo'` → `name = 'Foo'`).
/// Null for inline / anonymous schemas.
///
/// [isNullable] is normalized across OpenAPI 3.0 (`nullable: true`) and
/// 3.1/3.2 (`type: [T, null]`). Always use this field; never read `nullable`
/// directly from the raw spec map.
@immutable
sealed class SchemaObject {
  final String? name;
  final String? description;
  final bool isNullable;

  const SchemaObject({this.name, this.description, this.isNullable = false});
}

/// An OpenAPI `type: object` schema (or a schema with `properties` and no explicit type).
///
/// [properties] is a list of named, typed properties.
/// [required] is the list of property names declared required in the spec.
/// [additionalProperties] is typed [Object?]:
///   - `null`  → not specified
///   - `true`  → free-form map allowed (`Map<String, dynamic>`)
///   - `false` → no additional properties beyond declared ones
///   - [SchemaObject] → typed additional properties (`Map<String, T>`)
@immutable
final class ObjectSchema extends SchemaObject {
  final List<SchemaProperty> properties;
  final List<String> required;
  final Object? additionalProperties; // bool | SchemaObject | null

  const ObjectSchema({
    super.name,
    super.description,
    super.isNullable,
    required this.properties,
    required this.required,
    this.additionalProperties,
  });
}

/// An OpenAPI `enum` schema.
///
/// [enumType] is the underlying primitive type: `'string'`, `'integer'`, or `'number'`.
/// [values] preserves wire-value casing (do NOT normalise to Dart-friendly names here;
/// that is NameRegistry's job).
@immutable
final class EnumSchema extends SchemaObject {
  final String enumType;
  final List<dynamic> values;

  const EnumSchema({
    super.name,
    super.description,
    super.isNullable,
    required this.enumType,
    required this.values,
  });
}

/// An OpenAPI primitive schema: `string`, `integer`, `number`, or `boolean`.
///
/// [format] captures `format: date-time`, `format: int64`, etc. May be null.
@immutable
final class PrimitiveSchema extends SchemaObject {
  final String primitiveType; // 'string' | 'integer' | 'number' | 'boolean'
  final String? format;

  const PrimitiveSchema({
    super.name,
    super.description,
    super.isNullable,
    required this.primitiveType,
    this.format,
  });
}

/// An OpenAPI `type: array` schema.
///
/// [items] is the resolved element schema. Never null — OpenAPI requires `items`
/// for array schemas (parser throws [OpenApiParseException] if absent).
@immutable
final class ArraySchema extends SchemaObject {
  final SchemaObject items;

  const ArraySchema({
    super.name,
    super.description,
    super.isNullable,
    required this.items,
  });
}

/// An OpenAPI `allOf` composition schema.
///
/// [schemas] is the ordered list of resolved member schemas (after `$ref` resolution).
@immutable
final class AllOfSchema extends SchemaObject {
  final List<SchemaObject> schemas;

  const AllOfSchema({
    super.name,
    super.description,
    super.isNullable,
    required this.schemas,
  });
}

/// An OpenAPI `oneOf` composition schema with optional discriminator.
///
/// [variants] is the list of resolved variant schemas (after `$ref` resolution).
/// [discriminatorPropertyName] is the value of `discriminator.propertyName`.
/// [discriminatorMapping] is the optional `discriminator.mapping` object.
/// Discriminator validation happens at parse time in SchemaParser,
/// not here.
@immutable
final class OneOfSchema extends SchemaObject {
  final List<SchemaObject> variants;
  final String? discriminatorPropertyName;
  final Map<String, String>? discriminatorMapping;

  const OneOfSchema({
    super.name,
    super.description,
    super.isNullable,
    required this.variants,
    this.discriminatorPropertyName,
    this.discriminatorMapping,
  });
}

/// An OpenAPI `type: null` schema (OpenAPI 3.1+ only).
///
/// Represents a standalone null schema. Not used for nullable fields (which
/// use [isNullable] on the enclosing schema); only emitted when the schema
/// itself IS the null type.
@immutable
final class NullSchema extends SchemaObject {
  const NullSchema({super.name, super.description});
}

/// Sentinel subtype emitted by [RefResolver] when a `$ref` cycle is detected.
///
/// Represents a forward reference to a schema that is still being resolved.
/// Generators MUST check for this with [isCyclicRef] and emit `late` or
/// nullable Dart fields to handle the recursive type correctly.
///
/// Private — not exported from the library. Only [RefResolver] constructs it;
/// downstream code pattern-matches on [SchemaObject] sealed subtypes and
/// must include a case for [_CyclicRefSchema].
@immutable
// ignore: unused_element
final class _CyclicRefSchema extends SchemaObject {
  /// The JSON pointer of the schema being referenced cyclically.
  /// Example: `/components/schemas/User`
  final String refPointer;

  // ignore: unused_element
  const _CyclicRefSchema({
    required this.refPointer,
    // ignore: unused_element_parameter
    super.name,
  });
}

/// A named, typed property within an [ObjectSchema] or [AllOfSchema].
///
/// [specName] is the original property name from the spec (may be snake_case,
/// kebab-case, camelCase, etc.). NameRegistry converts this to a Dart field name.
/// [isRequired] reflects whether this property appears in the parent schema's
/// `required` array.
@immutable
final class SchemaProperty {
  final String specName;
  final SchemaObject schema;
  final bool isRequired;

  const SchemaProperty({
    required this.specName,
    required this.schema,
    required this.isRequired,
  });
}

/// Package-private factory for creating [_CyclicRefSchema] sentinels.
///
/// Only [RefResolver] should call this. The returned [SchemaObject] carries
/// [refPointer] so generators can detect recursive types and emit `late` fields.
SchemaObject createCyclicRef(String refPointer) =>
    _CyclicRefSchema(refPointer: refPointer);

/// Returns `true` if [schema] is a cyclic-ref sentinel emitted by [RefResolver].
///
/// Use this to detect recursive fields without naming the private
/// [_CyclicRefSchema] type. Code outside this library cannot name [_CyclicRefSchema]
/// in a switch arm due to Dart's library privacy rules.
bool isCyclicRef(SchemaObject schema) => schema is _CyclicRefSchema;

/// Returns the target spec name for a cyclic-ref sentinel.
///
/// Example: a sentinel for `/components/schemas/User` returns `'User'`.
/// Only call this when [isCyclicRef(schema)] is `true`.
String cyclicRefTargetName(SchemaObject schema) {
  assert(
    schema is _CyclicRefSchema,
    'cyclicRefTargetName called on non-cyclic schema: $schema',
  );
  final s = schema as _CyclicRefSchema;
  return s.refPointer.split('/').last;
}
