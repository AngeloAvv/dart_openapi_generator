import '../date_time_converter.dart';
import '../model/media_type.dart';
import '../model/schema_object.dart';
import '../model/spec_document.dart';
import '../name_registry/name_registry.dart';
import 'code_builder_helpers.dart';

/// One property of a form body model (`application/x-www-form-urlencoded` or
/// `multipart/form-data`), as the service method encodes it.
final class FormProperty {
  /// The property name in the spec, i.e. the field name on the wire.
  final String wireName;

  /// The Dart field holding it on the body model.
  final String fieldName;

  final SchemaObject schema;

  /// Whether the Dart field is nullable: an optional property, or a
  /// `nullable` one. A null value is never sent.
  final bool isNullable;

  /// The Encoding Object declared for this property, if any.
  final EncodingObject? encoding;

  const FormProperty({
    required this.wireName,
    required this.fieldName,
    required this.schema,
    required this.isNullable,
    this.encoding,
  });
}

/// The properties of the form body model [modelSpecName], whose schema is
/// [schema], in spec order; null when the schema is not an object the
/// generator can encode field by field.
///
/// An `allOf` is merged the way [ModelGenerator] merges it — the `object`
/// members only, first occurrence of a property wins, `required` lists
/// unioned — so every property listed here is a field of the generated class.
List<FormProperty>? formProperties(
  SchemaObject schema,
  String modelSpecName,
  NameRegistry registry,
  Map<String, EncodingObject> encoding,
) {
  final List<SchemaProperty> properties;
  final Set<String> required;
  switch (schema) {
    case ObjectSchema():
      properties = schema.properties;
      required = schema.required.toSet();
    case AllOfSchema():
      final merged = <String, SchemaProperty>{};
      required = {};
      for (final member in schema.schemas) {
        if (member is! ObjectSchema) continue;
        for (final prop in member.properties) {
          merged.putIfAbsent(prop.specName, () => prop);
        }
        required.addAll(member.required);
      }
      properties = merged.values.toList();
    default:
      return null;
  }
  return [
    for (final prop in properties)
      FormProperty(
        wireName: prop.specName,
        fieldName: registry.dartFieldName(modelSpecName, prop.specName),
        schema: prop.schema,
        isNullable:
            !(prop.isRequired || required.contains(prop.specName)) ||
            prop.schema.isNullable,
        encoding: encoding[prop.specName],
      ),
  ];
}

/// Encodes form bodies into Dart statements of a generated service method.
///
/// Both encoders read the body model through its fields and never send a
/// null value: an optional property left unset, and a `nullable` one set to
/// null, are omitted from the body, exactly as `toJson()` omits them.
final class FormBodyEncoder {
  final DateTimeConverter _dateTimeConverter;

  /// Receives one message per spec construct that cannot be encoded as the
  /// spec describes it; the message is completed by the caller with the
  /// operation it belongs to.
  final void Function(String) _warn;

  const FormBodyEncoder(this._dateTimeConverter, this._warn);

  // ---------------------------------------------------------------------------
  // application/x-www-form-urlencoded
  // ---------------------------------------------------------------------------

  /// The `ListFormat` of each array property whose serialization differs from
  /// Dio's default (`ListFormat.multi`, i.e. `tags=a&tags=b` — the OpenAPI
  /// default `style: form`, `explode: true`), keyed by wire name.
  ///
  /// The body itself is sent as `body.toJson()`, which Dio encodes:
  /// scalars as text (`true`/`false` for booleans), date-times and enums
  /// through their `toJson()` wire value, nested objects in bracket notation
  /// (`meta%5Bkey%5D=value`, the `deepObject` style). Every construct whose
  /// declared serialization this cannot honour is reported to the warning
  /// sink.
  Map<String, String> urlEncodedListFormats(List<FormProperty> properties) {
    final formats = <String, String>{};
    for (final p in properties) {
      final encoding = p.encoding;
      final schema = _effective(p.schema);
      final style = encoding?.style ?? 'form';
      final explode = encoding?.explode ?? style == 'form';

      if (encoding?.allowReserved ?? false) {
        _warn(
          'form property "${p.wireName}" declares "allowReserved: true", which '
          'is not supported: reserved characters are percent-encoded.',
        );
      }
      if (encoding?.contentType != null) {
        _warn(
          'form property "${p.wireName}" declares the content type '
          '"${encoding!.contentType}", which is ignored for '
          'application/x-www-form-urlencoded: the value is sent as text.',
        );
      }

      if (_isObjectLike(schema)) {
        if (style != 'deepObject') {
          _warn(
            'form property "${p.wireName}" is an object; it is sent in bracket '
            'notation ("${p.wireName}[key]=value", the deepObject style), not '
            'in the "$style" style the spec declares.',
          );
        }
      } else if (schema is ArraySchema) {
        if (_isObjectLike(_effective(schema.items))) {
          _warn(
            'form property "${p.wireName}" is an array of objects, which '
            'OpenAPI does not define for forms; it is sent in bracket '
            'notation ("${p.wireName}[0][key]=value").',
          );
        } else if (!explode) {
          final format = switch (style) {
            'form' => 'ListFormat.csv',
            'spaceDelimited' => 'ListFormat.ssv',
            'pipeDelimited' => 'ListFormat.pipes',
            _ => null,
          };
          if (format == null) {
            _warn(
              'form property "${p.wireName}" declares the unsupported style '
              '"$style"; it is sent as repeated fields '
              '("${p.wireName}=a&${p.wireName}=b").',
            );
          } else {
            formats[p.wireName] = format;
          }
        }
      }
    }
    return formats;
  }

  // ---------------------------------------------------------------------------
  // multipart/form-data
  // ---------------------------------------------------------------------------

  /// The statements adding every property of `body` to a `FormData` named
  /// `formData`.
  ///
  /// One part per property, in spec order; an array is sent as one part per
  /// item, all under the property name. Following the Encoding Object
  /// defaults: a scalar is a text field, a binary property is a file part (a
  /// `clone()` of the caller's `MultipartFile`, which is therefore never used
  /// up), an object is an `application/json` part. A declared
  /// `encoding.contentType` turns a scalar into a part of that type.
  List<String> multipartStatements(List<FormProperty> properties) {
    final lines = <String>[];
    for (final p in properties) {
      final encoding = p.encoding;
      if (encoding?.hasHeaders ?? false) {
        _warn(
          'multipart property "${p.wireName}" declares per-part headers, which '
          'are not generated.',
        );
      }
      final access = 'body.${p.fieldName}';
      final value = p.isNullable ? '$access!' : access;
      final schema = _effective(p.schema);
      final List<String> adds;
      if (schema is ArraySchema && !isBinarySchema(schema)) {
        final itemAdd = _partAdd(p, _effective(schema.items), 'item');
        adds = ['for (final item in $value) {', itemAdd, '}'];
      } else if (schema is ArraySchema) {
        adds = [
          'for (final item in $value) {',
          'formData.files.add(MapEntry(${dartStringLiteral(p.wireName)}, item.clone()));',
          '}',
        ];
      } else {
        adds = [_partAdd(p, schema, value)];
      }
      if (p.isNullable) {
        lines
          ..add('if ($access != null) {')
          ..addAll(adds)
          ..add('}');
      } else {
        lines.addAll(adds);
      }
    }
    return lines;
  }

  /// The statement adding the part [value] (one property, or one item of an
  /// array property) of [property], whose schema is [schema].
  String _partAdd(FormProperty property, SchemaObject schema, String value) {
    final name = dartStringLiteral(property.wireName);

    if (isBinarySchema(schema)) {
      return 'formData.files.add(MapEntry($name, $value.clone()));';
    }

    final contentType = _partContentType(property);
    final String? text = _textValue(schema, value);
    if (text != null) {
      if (contentType == null) {
        return 'formData.fields.add(MapEntry($name, $text));';
      }
      return 'formData.files.add(MapEntry($name, '
          'MultipartFile.fromString($text, '
          'contentType: DioMediaType.parse(${dartStringLiteral(contentType)}))));';
    }

    // An object (or anything else without a text form): a JSON part.
    if (schema is ArraySchema) {
      _warn(
        'multipart property "${property.wireName}" is an array of arrays; each '
        'inner array is sent as a JSON part.',
      );
    }
    final json = _hasToJson(schema) ? '$value.toJson()' : value;
    var partType = "DioMediaType('application', 'json')";
    if (contentType != null) {
      if (classifyMediaType(contentType) == MediaTypeKind.json) {
        partType = 'DioMediaType.parse(${dartStringLiteral(contentType)})';
      } else {
        _warn(
          'multipart property "${property.wireName}" is an object declared as '
          '"$contentType"; only JSON is generated for object parts, so it is '
          'sent as application/json.',
        );
      }
    }
    return 'formData.files.add(MapEntry($name, '
        'MultipartFile.fromString(jsonEncode($json), contentType: $partType)));';
  }

  /// The media type of the part sent for [property], from its
  /// `encoding.contentType`; null for the default type of the part.
  ///
  /// The Encoding Object allows a comma-separated list and media type ranges,
  /// but a part is sent with a single, concrete type, which
  /// `DioMediaType.parse` must accept: the first concrete entry of a list is
  /// used, and a value without one falls back to the default. Both cases are
  /// warned about.
  String? _partContentType(FormProperty property) {
    final declared = property.encoding?.contentType;
    if (declared == null) return null;
    final entries = [
      for (final entry in declared.split(','))
        if (entry.trim().isNotEmpty) entry.trim(),
    ];
    final concrete =
        entries
            .where((entry) => _concreteMediaType.hasMatch(entry))
            .firstOrNull;
    if (concrete == null) {
      _warn(
        'multipart property "${property.wireName}" declares the content type '
        '"$declared", which has no concrete media type; the part is sent with '
        'its default type.',
      );
    } else if (entries.length > 1) {
      _warn(
        'multipart property "${property.wireName}" declares several content '
        'types ("$declared"); the part is sent as "$concrete".',
      );
    }
    return concrete;
  }

  /// The `String` sent for the scalar [value] of [schema], or null when the
  /// schema is not a scalar.
  String? _textValue(SchemaObject schema, String value) {
    if (isCyclicRef(schema)) return null;
    return switch (schema) {
      PrimitiveSchema(primitiveType: 'string', format: 'date-time') =>
        _dateTimeConverter == DateTimeConverter.timestamp
            ? '$value.millisecondsSinceEpoch.toString()'
            : '$value.toIso8601String()',
      PrimitiveSchema(primitiveType: 'string') => value,
      PrimitiveSchema() => '$value.toString()',
      EnumSchema(enumType: 'string') when schema.name != null =>
        '$value.toJson()',
      EnumSchema() when schema.name != null => '$value.toJson().toString()',
      // An inline enum is typed with its primitive.
      EnumSchema(enumType: 'string') => value,
      EnumSchema() => '$value.toString()',
      _ => null,
    };
  }

  /// Whether the Dart type of [schema] is a generated class with `toJson()`;
  /// otherwise the value is already JSON (a `Map` or a `List`).
  bool _hasToJson(SchemaObject schema) =>
      isCyclicRef(schema) ||
      (schema.name != null &&
          (schema is ObjectSchema ||
              schema is AllOfSchema ||
              schema is OneOfSchema));
}

/// Whether the media type of an operation is one of the two form kinds.
bool isFormKind(MediaTypeKind? kind) =>
    kind == MediaTypeKind.formUrlEncoded || kind == MediaTypeKind.multipart;

/// A media type without wildcards, `type/subtype` optionally followed by
/// parameters (RFC 9110 tokens).
final _concreteMediaType = RegExp(
  r"^[!#$%&'+.^_`|~0-9A-Za-z-]+/[!#$%&'+.^_`|~0-9A-Za-z-]+\s*(;.*)?$",
);

bool _isObjectLike(SchemaObject schema) =>
    isCyclicRef(schema) ||
    schema is ObjectSchema ||
    schema is AllOfSchema ||
    schema is OneOfSchema;

/// Unwraps an anonymous single-member `allOf` (the OpenAPI 3.0 `nullable`
/// pattern, `allOf: [$ref]`) to the schema carrying the type.
SchemaObject _effective(SchemaObject schema) => switch (schema) {
  AllOfSchema() when schema.name == null && schema.schemas.length == 1 =>
    schema.schemas.first,
  _ => schema,
};
