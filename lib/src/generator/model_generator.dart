import 'package:code_builder/code_builder.dart';

import '../date_time_converter.dart';
import '../model/openapi_parse_exception.dart';
import '../model/schema_object.dart';
import '../model/spec_document.dart';
import '../name_registry/keyword_escaper.dart';
import '../name_registry/name_converter.dart';
import '../name_registry/name_registry.dart';
import 'code_builder_emitter.dart';
import 'code_builder_helpers.dart';

/// Converts a [SpecDocument]'s schemas into a map of filename → Dart source.
///
/// Each entry in [SpecDocument.schemas] produces one file under the `models/`
/// prefix. The returned map is written to disk by [FileWriter].
///
/// Key format: `'models/<snake_case_name>.dart'`
///
/// Usage:
/// ```dart
/// final generator = ModelGenerator(registry, DateTimeConverter.iso8601);
/// final files = generator.generate(document);
/// ```
final class ModelGenerator {
  final NameRegistry _registry;
  final DateTimeConverter _dateTimeConverter;

  /// Optional warning sink for enum value sanitization and other advisory
  /// messages. Callers should route this to `log.warning` in the builder context.
  final void Function(String)? onWarning;

  const ModelGenerator(
    this._registry,
    this._dateTimeConverter, {
    this.onWarning,
  });

  /// Generates one Dart source file per schema in [document].
  ///
  /// Schemas are processed in alphabetical order.
  /// Empty results (NullSchema, cyclic sentinels at top level) are filtered.
  ///
  /// Schemas that are inline variants of a oneOf sealed class are NOT emitted as
  /// standalone files — their classes are inlined into the sealed parent file
  /// (e.g. EmailNotification is emitted inside notification.dart, NOT as a
  /// separate email_notification.dart). This avoids ambiguous_export errors in
  /// the barrel when both the parent and variant files would define the same
  /// class name.
  ///
  /// Returns `Map<String, String>` where keys are `'models/<name>.dart'`
  /// and values are formatted Dart source strings.
  Map<String, String> generate(SpecDocument document) {
    // Build the set of spec names that are oneOf variants. These schemas will
    // be emitted inline inside their parent sealed class file and must NOT
    // receive a standalone file.
    final variantSpecNames =
        document.schemas.entries.where((e) => e.value is OneOfSchema).expand((
          e,
        ) {
          final schema = e.value as OneOfSchema;
          return schema.variants.indexed.map(
            (iv) => iv.$2.name ?? '${e.key}Variant${iv.$1}',
          );
        }).toSet();

    final sortedNames = document.schemas.keys.toList()..sort();
    final result = <String, String>{};
    for (final specName in sortedNames) {
      // Skip variant schemas — they are inlined by _emitSealedClass.
      if (variantSpecNames.contains(specName)) continue;
      final schema = document.schemas[specName]!;
      final source = _emitSchema(specName, schema);
      if (source.isNotEmpty) {
        final fileName =
            'models/${toSnakeCase(_registry.dartClassName(specName))}.dart';
        result[fileName] = source;
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Top-level dispatch
  // ---------------------------------------------------------------------------

  String _emitSchema(String specName, SchemaObject schema) {
    // _CyclicRefSchema is private to schema_object.dart; use isCyclicRef() to
    // detect it before entering the switch. A top-level cyclic-ref sentinel
    // means the schema IS the cycle root — skip file emission but warn the user.
    if (isCyclicRef(schema)) {
      final targetName = cyclicRefTargetName(schema);
      onWarning?.call(
        'Cyclic reference detected for type "$targetName" — skipping top-level '
        'file emission for "$specName". The type will be referenced as a late field.',
      );
      return '';
    }
    return switch (schema) {
      ObjectSchema() => _emitObjectClass(specName, schema),
      EnumSchema() => _emitEnum(specName, schema),
      PrimitiveSchema() => _emitPrimitiveDef(specName, schema),
      ArraySchema() => _emitArrayDef(specName, schema),
      AllOfSchema() => _emitAllOfClass(specName, schema),
      OneOfSchema() => _emitSealedClass(specName, schema),
      NullSchema() => '', // top-level null schema: skip file emission
      // Unreachable: _CyclicRefSchema is caught above by isCyclicRef() guard.
      _ => '',
    };
  }

  // ---------------------------------------------------------------------------
  // ObjectSchema emission
  // ---------------------------------------------------------------------------

  /// Collects import paths for all schema types referenced in [props].
  ///
  /// Returns a sorted list of relative import strings of the form
  /// `'<snake_name>.dart'` (relative to the `models/` directory),
  /// excluding the file for [selfClassName] (to avoid self-imports).
  ///
  /// [selfClassName] is the PascalCase Dart class name of the file being
  /// generated (e.g. 'User', 'UserProfile').
  List<String> _collectImportsForProps(
    String selfClassName,
    List<_ResolvedProp> props,
  ) {
    final imports = <String>{};
    final selfFile = '${toSnakeCase(selfClassName)}.dart';
    for (final p in props) {
      if (p.isCyclic) {
        // isCyclicTarget is the PascalCase class name of the referenced type.
        final targetClass = p.isCyclicTarget;
        if (targetClass != null) {
          final file = '${toSnakeCase(targetClass)}.dart';
          if (file != selfFile) imports.add(file);
        }
        continue;
      }
      final schema = p.schema;
      if (schema == null) continue;
      _addImportForSchema(selfFile, schema, imports);
    }
    return imports.toList()..sort();
  }

  /// Recursively collects import paths for a [schema] reference.
  ///
  /// [selfFile] is the snake_case filename of the file being generated
  /// (e.g. 'user.dart') — used to skip self-imports.
  void _addImportForSchema(
    String selfFile,
    SchemaObject schema,
    Set<String> imports,
  ) {
    if (isCyclicRef(schema)) {
      final targetName = cyclicRefTargetName(schema);
      final targetClass = _registry.dartClassName(targetName);
      final file = '${toSnakeCase(targetClass)}.dart';
      if (file != selfFile) imports.add(file);
      return;
    }
    switch (schema) {
      case EnumSchema() when schema.name != null:
        final className = _registry.dartClassName(schema.name!);
        final file = '${toSnakeCase(className)}.dart';
        if (file != selfFile) imports.add(file);
      case ObjectSchema() when schema.name != null:
        final className = _registry.dartClassName(schema.name!);
        final file = '${toSnakeCase(className)}.dart';
        if (file != selfFile) imports.add(file);
      case AllOfSchema() when schema.name != null:
        final className = _registry.dartClassName(schema.name!);
        final file = '${toSnakeCase(className)}.dart';
        if (file != selfFile) imports.add(file);
      case OneOfSchema() when schema.name != null:
        final className = _registry.dartClassName(schema.name!);
        final file = '${toSnakeCase(className)}.dart';
        if (file != selfFile) imports.add(file);
      case ArraySchema():
        _addImportForSchema(selfFile, schema.items, imports);
      default:
        break; // primitives and anonymous objects need no import
    }
  }

  String _emitObjectClass(
    String specName,
    ObjectSchema schema, {
    String? extendsClause,
  }) {
    final className = _registry.dartClassName(specName);

    // Resolve properties sorted alphabetically by Dart field name
    final resolvedProps = _resolveProperties(specName, schema);

    // Check for additionalProperties field.
    // Guard: skip synthetic entry if a real property already uses the same
    // specName to avoid duplicate fields and constructor params (CR-01).
    final hasAdditionalProps =
        schema.additionalProperties != null &&
        schema.additionalProperties != false &&
        schema.properties.every((p) => p.specName != 'additionalProperties');

    // Build the additional props entry if needed.
    // Use the sentinel specName '\$additionalProperties' to distinguish the
    // synthetic entry from any real spec property named 'additionalProperties'.
    _ResolvedProp? additionalPropEntry;
    if (hasAdditionalProps) {
      final apType = _additionalPropsType(
        specName,
        schema.additionalProperties,
      );
      // Pass the SchemaObject (if typed) so that fromJson/toJson can dispatch
      // through the typed value expressions.
      final apSchema =
          schema.additionalProperties is SchemaObject
              ? schema.additionalProperties as SchemaObject
              : null;
      additionalPropEntry = _ResolvedProp(
        specName: r'$additionalProperties',
        fieldName: 'additionalProperties',
        dartType: apType,
        isNullable: false, // always present (defaults to empty map)
        isRequired: true,
        isListType: false,
        isMapType: true,
        isCyclic: false,
        isCyclicTarget: null,
        isEnumType: false,
        isPrimitive: false,
        isDateTime: false,
        dateTimeIsTimestamp: false,
        isListOfGenerated: false,
        isMapOfGenerated: false,
        schema: apSchema,
      );
    }

    // Merge and sort all props alphabetically by fieldName
    final allProps = [
      ...resolvedProps,
      if (additionalPropEntry != null) additionalPropEntry,
    ]..sort((a, b) => a.fieldName.compareTo(b.fieldName));

    // Determine const-eligibility
    final isConstEligible = _isConstEligible(allProps);

    // Determine which helpers are needed
    final needsUndefined = allProps.any((p) => p.isNullable);
    final needsListEquals = allProps.any((p) => p.isListType);
    final needsMapEquals = allProps.any((p) => p.isMapType);

    // Collect imports for referenced types.
    // Pass the PascalCase class name so self-import detection works correctly
    // (compares file names, not spec names).
    final imports = _collectImportsForProps(className, allProps);

    return emitLibrary(
      Library((lib) {
        for (final imp in imports) {
          lib.directives.add(Directive.import(imp));
        }
        if (needsUndefined) {
          lib.body.add(_undefinedSentinelClass);
          lib.body.add(_undefinedSentinelField);
        }
        if (needsListEquals) lib.body.add(_listEqualsMethod());
        if (needsMapEquals) lib.body.add(_mapEqualsMethod());
        lib.body.add(
          _buildObjectClass(
            className: className,
            props: allProps,
            isConstEligible: isConstEligible,
            extendsClause: extendsClause,
            needsUndefined: needsUndefined,
          ),
        );
      }),
    );
  }

  Class _buildObjectClass({
    required String className,
    required List<_ResolvedProp> props,
    required bool isConstEligible,
    String? extendsClause,
    required bool needsUndefined,
  }) {
    return Class((c) {
      c.modifier = ClassModifier.final$;
      c.name = className;
      if (extendsClause != null) c.extend = refer(extendsClause);

      // Fields
      for (final p in props) {
        c.fields.add(
          Field((f) {
            f.modifier = FieldModifier.final$;
            f.name = p.fieldName;
            f.type = refer(p.isNullable ? '${p.dartType}?' : p.dartType);
            if (p.specName == r'$additionalProperties') {
              f.docs.add(
                '/// Additional properties from the JSON object. Always non-null; defaults to an empty map.',
              );
            }
          }),
        );
      }

      // Primary constructor
      c.constructors.add(
        Constructor((ctor) {
          if (isConstEligible) ctor.constant = true;
          for (final p in props) {
            ctor.optionalParameters.add(
              Parameter((param) {
                param.name = p.fieldName;
                param.toThis = true;
                param.named = true;
                param.required = !p.isNullable;
              }),
            );
          }
        }),
      );

      // fromJson factory
      c.constructors.add(_buildFromJsonConstructor(className, props));

      // toJson
      c.methods.add(_buildToJsonMethod(className, props, extendsClause));

      // copyWith
      c.methods.add(_buildCopyWithMethod(className, props));

      // operator ==
      c.methods.add(_buildEqualsMethod(className, props));

      // hashCode
      c.methods.add(_buildHashCodeMethod(props));
    });
  }

  Constructor _buildFromJsonConstructor(
    String className,
    List<_ResolvedProp> props,
  ) {
    final argLines = props
        .map((p) {
          if (p.specName == r'$additionalProperties') {
            if (p.schema != null) {
              final vfj = _schemaFromJsonExpr(
                p.schema!,
                'v',
                _dartType(className, p.schema!),
              );
              return "  ${p.fieldName}: ((json['additionalProperties'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, $vfj)),";
            } else {
              return "  ${p.fieldName}: Map<String, dynamic>.from((json['additionalProperties'] as Map?) ?? {}),";
            }
          } else if (p.isNullable) {
            final decode = _fromJsonExpr(
              p,
              "json['${p.specName}']",
              nullable: false,
            );
            return "  ${p.fieldName}: json['${p.specName}'] == null ? null : $decode,";
          } else {
            final decode = _fromJsonExpr(
              p,
              "json['${p.specName}']",
              nullable: false,
            );
            return "  ${p.fieldName}: json['${p.specName}'] == null\n      ? (throw ArgumentError.notNull('$className.${p.specName}'))\n      : $decode,";
          }
        })
        .join('\n');
    return Constructor((ctor) {
      ctor.factory = true;
      ctor.name = 'fromJson';
      ctor.lambda = true;
      ctor.requiredParameters.add(
        Parameter((p) {
          p.name = 'json';
          p.type = refer('Map<String, dynamic>');
        }),
      );
      ctor.body = Code('$className(\n$argLines\n)');
    });
  }

  Method _buildToJsonMethod(
    String className,
    List<_ResolvedProp> props,
    String? extendsClause,
  ) {
    final entryLines = props
        .map((p) {
          if (p.specName == r'$additionalProperties') {
            if (p.schema != null && _isGeneratedType(p.schema!)) {
              return "  if (${p.fieldName}.isNotEmpty) 'additionalProperties': ${p.fieldName}.map((k, v) => MapEntry(k, v.toJson())),";
            } else {
              return "  if (${p.fieldName}.isNotEmpty) 'additionalProperties': ${p.fieldName},";
            }
          } else if (p.isNullable) {
            final encode = _toJsonExpr(p);
            return "  if (${p.fieldName} != null) '${p.specName}': $encode,";
          } else {
            final encode = _toJsonExpr(p);
            return "  '${p.specName}': $encode,";
          }
        })
        .join('\n');
    return Method((m) {
      if (extendsClause != null) m.annotations.add(refer('override'));
      m.name = 'toJson';
      m.returns = refer('Map<String, dynamic>');
      m.lambda = true;
      m.body = Code('{\n$entryLines\n}');
    });
  }

  Method _buildCopyWithMethod(String className, List<_ResolvedProp> props) {
    final argLines = props
        .map((p) {
          if (p.isNullable) {
            return "  ${p.fieldName}: identical(${p.fieldName}, _undefined) ? this.${p.fieldName} : ${p.fieldName} as ${p.dartType}?,";
          } else {
            return "  ${p.fieldName}: ${p.fieldName} ?? this.${p.fieldName},";
          }
        })
        .join('\n');
    return Method((m) {
      m.name = 'copyWith';
      m.returns = refer(className);
      for (final p in props) {
        m.optionalParameters.add(
          Parameter((param) {
            param.name = p.fieldName;
            param.named = true;
            if (p.isNullable) {
              param.type = refer('Object?');
              param.defaultTo = Code('_undefined');
            } else {
              param.type = refer('${p.dartType}?');
            }
          }),
        );
      }
      m.lambda = true;
      m.body = Code('$className(\n$argLines\n)');
    });
  }

  Method _buildEqualsMethod(String className, List<_ResolvedProp> props) {
    final condLines =
        props.isEmpty
            ? 'other is $className'
            : [
              'other is $className &&',
              ...props.indexed.map((iv) {
                final p = iv.$2;
                final isLast = iv.$1 == props.length - 1;
                final suffix = isLast ? '' : ' &&';
                if (p.isListType) {
                  return '    _listEquals(${p.fieldName}, other.${p.fieldName})$suffix';
                } else if (p.isMapType) {
                  return '    _mapEquals(${p.fieldName}, other.${p.fieldName})$suffix';
                } else {
                  return '    ${p.fieldName} == other.${p.fieldName}$suffix';
                }
              }),
            ].join('\n');
    return Method((m) {
      m.annotations.add(refer('override'));
      m.name = 'operator ==';
      m.returns = refer('bool');
      m.requiredParameters.add(
        Parameter((p) {
          p.name = 'other';
          p.type = refer('Object');
        }),
      );
      m.lambda = true;
      m.body = Code('identical(this, other) ||\n    $condLines');
    });
  }

  Method _buildHashCodeMethod(List<_ResolvedProp> props) {
    return Method((m) {
      m.annotations.add(refer('override'));
      m.name = 'hashCode';
      m.type = MethodType.getter;
      m.returns = refer('int');
      m.lambda = true;
      if (props.isEmpty) {
        m.body = Code('runtimeType.hashCode');
      } else if (props.length == 1) {
        final p = props.first;
        if (p.isListType || p.isMapType) {
          final expr =
              p.isListType
                  ? (p.isNullable ? '${p.fieldName} ?? []' : p.fieldName)
                  : (p.isNullable
                      ? '(${p.fieldName} ?? {}).entries.map((e) => Object.hash(e.key, e.value))'
                      : '${p.fieldName}.entries.map((e) => Object.hash(e.key, e.value))');
          m.body = Code('Object.hashAll($expr)');
        } else {
          m.body = Code('${p.fieldName}.hashCode');
        }
      } else {
        final hashLines = <String>[];
        for (final p in props) {
          if (p.isListType) {
            final v = p.isNullable ? '${p.fieldName} ?? []' : p.fieldName;
            hashLines.add('  Object.hashAll($v),');
          } else if (p.isMapType) {
            final v =
                p.isNullable
                    ? '(${p.fieldName} ?? {}).entries.map((e) => Object.hash(e.key, e.value))'
                    : '${p.fieldName}.entries.map((e) => Object.hash(e.key, e.value))';
            hashLines.add('  Object.hashAll($v),');
          } else {
            hashLines.add('  ${p.fieldName},');
          }
        }
        // Object.hash accepts at most 20 positional arguments; fall back to
        // Object.hashAll when props exceed that limit.
        if (hashLines.length <= 20) {
          m.body = Code('Object.hash(\n${hashLines.join('\n')}\n)');
        } else {
          final listItems = hashLines
              .map((l) => l.trimRight().replaceAll(RegExp(r',$'), ''))
              .join(',\n');
          m.body = Code('Object.hashAll([\n$listItems,\n])');
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // EnumSchema emission
  // ---------------------------------------------------------------------------

  String _emitEnum(String specName, EnumSchema schema) {
    final className = _registry.dartClassName(specName);

    // Sanitize and sort enum values alphabetically by Dart identifier
    final entries = <({String wire, String dart})>[];
    for (final wireValue in schema.values) {
      final wire = wireValue.toString();
      final dart = _sanitizeEnumIdentifier(wire);
      if (dart != wire) {
        onWarning?.call('Enum value sanitized: "$wire" → "$dart" in $specName');
      }
      entries.add((wire: wire, dart: dart));
    }
    entries.sort((a, b) => a.dart.compareTo(b.dart));

    // Detect duplicate Dart identifiers produced by sanitization.
    final seen = <String>{};
    for (final e in entries) {
      if (!seen.add(e.dart)) {
        throw OpenApiParseException(
          'Enum "$specName": two wire values sanitize to the same Dart '
          'identifier "${e.dart}". Rename one value in the spec.',
          jsonPointer: '#/components/schemas/$specName/enum',
        );
      }
    }

    // Determine fromJson/toJson parameter type
    final String jsonType;
    if (schema.enumType == 'integer') {
      jsonType = 'int';
    } else if (schema.enumType == 'number') {
      jsonType = 'double';
    } else {
      jsonType = 'String';
    }

    return emitLibrary(
      Library((lib) {
        lib.body.add(
          Enum((e) {
            e.name = className;
            for (final entry in entries) {
              e.values.add(EnumValue((v) => v.name = entry.dart));
            }
            e.methods.add(
              Method((m) {
                m.static = true;
                m.name = 'fromJson';
                m.returns = refer(className);
                m.requiredParameters.add(
                  Parameter((p) {
                    p.name = 'v';
                    p.type = refer(jsonType);
                  }),
                );
                m.lambda = true;
                m.body =
                    returnSwitch(
                      refer('v'),
                      cases: entries.map(
                        (entry) => (
                          _wireToLiteral(entry.wire, jsonType),
                          refer('$className.${entry.dart}'),
                        ),
                      ),
                      otherwise: CodeExpression(
                        Code(
                          "throw ArgumentError('Unknown $className value: \$v')",
                        ),
                      ),
                    ).code;
              }),
            );
            e.methods.add(
              Method((m) {
                m.name = 'toJson';
                m.returns = refer(jsonType);
                m.lambda = true;
                m.body =
                    returnSwitch(
                      refer('this'),
                      cases: entries.map(
                        (entry) => (
                          refer('$className.${entry.dart}'),
                          _wireToLiteral(entry.wire, jsonType),
                        ),
                      ),
                    ).code;
              }),
            );
          }),
        );
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // PrimitiveSchema emission (typedef)
  // ---------------------------------------------------------------------------

  String _emitPrimitiveDef(String specName, PrimitiveSchema schema) {
    final className = _registry.dartClassName(specName);
    final dartType = _primitiveType(schema.primitiveType, schema.format);
    return emitLibrary(
      Library((lib) {
        lib.body.add(
          TypeDef((t) {
            t.name = className;
            t.definition = refer(dartType);
          }),
        );
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // ArraySchema emission (typedef)
  // ---------------------------------------------------------------------------

  String _emitArrayDef(String specName, ArraySchema schema) {
    final className = _registry.dartClassName(specName);
    final itemType = _dartType(specName, schema.items);
    return emitLibrary(
      Library((lib) {
        lib.body.add(
          TypeDef((t) {
            t.name = className;
            t.definition = refer('List<$itemType>');
          }),
        );
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // AllOfSchema emission (flat merge)
  // ---------------------------------------------------------------------------

  String _emitAllOfClass(String specName, AllOfSchema schema) {
    // Merge all ObjectSchema members
    final mergedProperties =
        <String, SchemaProperty>{}; // specName → first seen
    final requiredSet = <String>{};

    for (final member in schema.schemas) {
      if (member is! ObjectSchema) continue;
      for (final prop in member.properties) {
        if (!mergedProperties.containsKey(prop.specName)) {
          mergedProperties[prop.specName] = prop;
        } else {
          // Compare schemas structurally, not just by runtimeType.
          // Two PrimitiveSchema instances with different primitiveType values
          // share the same runtimeType but represent different Dart types.
          final existing = mergedProperties[prop.specName]!;
          final typeMismatch =
              existing.schema.runtimeType != prop.schema.runtimeType ||
              (existing.schema is PrimitiveSchema &&
                  (existing.schema as PrimitiveSchema).primitiveType !=
                      (prop.schema as PrimitiveSchema).primitiveType);
          if (typeMismatch) {
            onWarning?.call(
              'allOf merge conflict: property "${prop.specName}" in "$specName" '
              'has conflicting types across members. Using first occurrence.',
            );
          }
        }
      }
      requiredSet.addAll(member.required);
    }

    // Build synthetic ObjectSchema for the merged class
    final mergedProps =
        mergedProperties.values.map((p) {
          final isRequired = requiredSet.contains(p.specName);
          return SchemaProperty(
            specName: p.specName,
            schema: p.schema,
            isRequired: isRequired,
          );
        }).toList();

    final syntheticSchema = ObjectSchema(
      name: schema.name,
      description: schema.description,
      isNullable: schema.isNullable,
      properties: mergedProps,
      required: requiredSet.toList(),
    );

    return _emitObjectClass(specName, syntheticSchema);
  }

  // ---------------------------------------------------------------------------
  // OneOfSchema emission (sealed class)
  // ---------------------------------------------------------------------------

  String _emitSealedClass(String specName, OneOfSchema schema) {
    final className = _registry.dartClassName(specName);

    // Resolve variants sorted alphabetically by class name
    final variants = <({String variantSpecName, ObjectSchema variantSchema})>[];
    for (var i = 0; i < schema.variants.length; i++) {
      final variant = schema.variants[i];
      String variantSpecName;
      if (variant.name != null) {
        variantSpecName = variant.name!;
      } else {
        onWarning?.call(
          'oneOf variant $i of "$specName" has no name; using index as fallback.',
        );
        variantSpecName = '${specName}Variant$i';
      }
      if (variant is ObjectSchema) {
        variants.add((
          variantSpecName: variantSpecName,
          variantSchema: variant,
        ));
      } else {
        // Warn about silently skipped non-ObjectSchema variants so the
        // caller knows the discriminator fromJson will have no arm for them.
        onWarning?.call(
          'oneOf variant "$variantSpecName" in "$specName" is not an '
          'ObjectSchema (type: ${variant.runtimeType}); skipped. The '
          'discriminator fromJson will not handle this variant.',
        );
      }
    }
    variants.sort(
      (a, b) => _registry
          .dartClassName(a.variantSpecName)
          .compareTo(_registry.dartClassName(b.variantSpecName)),
    );

    // Build discriminator mapping: wire value → variant spec name
    final Map<String, String> wireToVariantSpec;
    if (schema.discriminatorMapping != null) {
      // Keys are wire values, values are schema ref paths
      wireToVariantSpec = {
        for (final e in schema.discriminatorMapping!.entries)
          e.key: e.value.split('/').last,
      };
    } else {
      // Use variant name as wire value directly
      wireToVariantSpec = {
        for (final v in variants) v.variantSpecName: v.variantSpecName,
      };
    }

    // Determine if any variant needs helpers (for top-level helper generation)
    bool needsUndefined = false;
    bool needsListEquals = false;
    bool needsMapEquals = false;

    final variantResolvedProps =
        <({String variantSpecName, List<_ResolvedProp> props})>[];

    // Collect imports needed by variants (e.g. enum/model refs in variant props)
    final sealedImports = <String>{};
    final sealedFileName = '${toSnakeCase(className)}.dart';

    for (final v in variants) {
      final variantClass = _registry.dartClassName(v.variantSpecName);
      final props = _resolveProperties(v.variantSpecName, v.variantSchema);
      variantResolvedProps.add((
        variantSpecName: v.variantSpecName,
        props: props,
      ));
      if (props.any((p) => p.isNullable)) needsUndefined = true;
      if (props.any((p) => p.isListType)) needsListEquals = true;
      if (props.any((p) => p.isMapType)) needsMapEquals = true;
      // Collect imports for this variant's properties (self = sealed class file)
      for (final imp in _collectImportsForProps(variantClass, props)) {
        if (imp != sealedFileName) sealedImports.add(imp);
      }
    }

    final sortedSealedImports = sealedImports.toList()..sort();

    // Sealed class body: build fromJson factory and toJson abstract method as Code lines.
    // code_builder 4.x has no sealed class modifier — use Class.sealed = true instead.
    final sealedFromJson = _buildSealedFromJson(
      className,
      schema.discriminatorPropertyName,
      wireToVariantSpec,
    );
    final sealedClass = Class((c) {
      c.sealed = true;
      c.name = className;
      c.constructors.add(Constructor((ctor) => ctor.constant = true));
      c.constructors.add(sealedFromJson);
      c.methods.add(
        Method((m) {
          m.name = 'toJson';
          m.returns = refer('Map<String, dynamic>');
          // no body = abstract method
        }),
      );
    });

    return emitLibrary(
      Library((lib) {
        for (final imp in sortedSealedImports) {
          lib.directives.add(Directive.import(imp));
        }
        if (needsUndefined) {
          lib.body.add(_undefinedSentinelClass);
          lib.body.add(_undefinedSentinelField);
        }
        if (needsListEquals) lib.body.add(_listEqualsMethod());
        if (needsMapEquals) lib.body.add(_mapEqualsMethod());
        lib.body.add(sealedClass);
        for (final vr in variantResolvedProps) {
          final variantClassName = _registry.dartClassName(vr.variantSpecName);
          final isConstEligible = _isConstEligible(vr.props);
          lib.body.add(
            _buildObjectClass(
              className: variantClassName,
              props: vr.props,
              isConstEligible: isConstEligible,
              extendsClause: className,
              needsUndefined: needsUndefined,
            ),
          );
        }
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // Property resolution helpers
  // ---------------------------------------------------------------------------

  List<_ResolvedProp> _resolveProperties(String specName, ObjectSchema schema) {
    final result = <_ResolvedProp>[];

    for (final prop in schema.properties) {
      final fieldName = _registry.dartFieldName(specName, prop.specName);
      final isNullable = !prop.isRequired || prop.schema.isNullable;

      if (isCyclicRef(prop.schema)) {
        final targetName = cyclicRefTargetName(prop.schema);
        final targetClass = _registry.dartClassName(targetName);
        result.add(
          _ResolvedProp(
            specName: prop.specName,
            fieldName: fieldName,
            dartType: targetClass,
            isNullable: true, // cyclic refs are always nullable
            isRequired: prop.isRequired,
            isListType: false,
            isMapType: false,
            isCyclic: true,
            isCyclicTarget: targetClass,
            isEnumType: false,
            isPrimitive: false,
            isDateTime: false,
            dateTimeIsTimestamp: false,
            isListOfGenerated: false,
            isMapOfGenerated: false,
            schema: prop.schema,
          ),
        );
        continue;
      }

      final dartType = _dartType(specName, prop.schema);
      final isListType = dartType.startsWith('List<');
      final isMapType =
          dartType.startsWith('Map<') || dartType == 'Map<String, dynamic>';
      final isEnumType = prop.schema is EnumSchema;
      final isPrimitive = prop.schema is PrimitiveSchema;
      final isDateTime =
          prop.schema is PrimitiveSchema &&
          (prop.schema as PrimitiveSchema).format == 'date-time';
      final dateTimeIsTimestamp =
          isDateTime && _dateTimeConverter == DateTimeConverter.timestamp;
      final isListOfGenerated =
          isListType &&
          prop.schema is ArraySchema &&
          _isGeneratedType((prop.schema as ArraySchema).items);
      final isMapOfGenerated =
          isMapType &&
          prop.schema is ObjectSchema &&
          (prop.schema as ObjectSchema).name != null;

      result.add(
        _ResolvedProp(
          specName: prop.specName,
          fieldName: fieldName,
          dartType: dartType,
          isNullable: isNullable,
          isRequired: prop.isRequired,
          isListType: isListType,
          isMapType: isMapType,
          isCyclic: false,
          isCyclicTarget: null,
          isEnumType: isEnumType,
          isPrimitive: isPrimitive,
          isDateTime: isDateTime,
          dateTimeIsTimestamp: dateTimeIsTimestamp,
          isListOfGenerated: isListOfGenerated,
          isMapOfGenerated: isMapOfGenerated,
          schema: prop.schema,
        ),
      );
    }

    // Sort alphabetically by field name
    result.sort((a, b) => a.fieldName.compareTo(b.fieldName));
    return result;
  }

  bool _isGeneratedType(SchemaObject schema) {
    return (schema is ObjectSchema && schema.name != null) ||
        (schema is EnumSchema && schema.name != null) ||
        (schema is AllOfSchema && schema.name != null) ||
        (schema is OneOfSchema && schema.name != null);
  }

  // ---------------------------------------------------------------------------
  // Type mapping
  // ---------------------------------------------------------------------------

  String _dartType(String schemaName, SchemaObject schema) {
    if (isCyclicRef(schema)) {
      return _registry.dartClassName(cyclicRefTargetName(schema));
    }
    return switch (schema) {
      PrimitiveSchema() => _primitiveType(schema.primitiveType, schema.format),
      ArraySchema() => 'List<${_dartType(schemaName, schema.items)}>',
      ObjectSchema() when schema.name != null => _registry.dartClassName(
        schema.name!,
      ),
      ObjectSchema() => 'Map<String, dynamic>',
      EnumSchema() when schema.name != null => _registry.dartClassName(
        schema.name!,
      ),
      AllOfSchema() when schema.name != null => _registry.dartClassName(
        schema.name!,
      ),
      OneOfSchema() when schema.name != null => _registry.dartClassName(
        schema.name!,
      ),
      NullSchema() => 'dynamic',
      _ => 'dynamic',
    };
  }

  String _primitiveType(String primitiveType, String? format) {
    if (primitiveType == 'string' && format == 'date-time') return 'DateTime';
    return switch (primitiveType) {
      'string' => 'String',
      'integer' => 'int',
      'number' => 'double',
      'boolean' => 'bool',
      _ => 'dynamic',
    };
  }

  String _additionalPropsType(String schemaName, Object? additionalProperties) {
    if (additionalProperties == null || additionalProperties == true) {
      return 'Map<String, dynamic>';
    }
    if (additionalProperties == false) {
      return 'Map<String, dynamic>'; // shouldn't reach here, filtered above
    }
    if (additionalProperties is SchemaObject) {
      final valueType = _dartType(schemaName, additionalProperties);
      return 'Map<String, $valueType>';
    }
    return 'Map<String, dynamic>';
  }

  // ---------------------------------------------------------------------------
  // fromJson / toJson expressions
  // ---------------------------------------------------------------------------

  String _fromJsonExpr(
    _ResolvedProp p,
    String jsonAccess, {
    required bool nullable,
  }) {
    if (p.isCyclic) {
      return '${p.dartType}.fromJson($jsonAccess as Map<String, dynamic>)';
    }

    final schema = p.schema;
    if (schema == null) return jsonAccess;

    if (schema is PrimitiveSchema) {
      return _primitiveFromJson(schema, jsonAccess);
    }

    if (schema is ArraySchema) {
      final itemType = _dartType('', schema.items);
      final itemExpr = _schemaFromJsonExpr(schema.items, 'e', itemType);
      if (itemExpr == 'e') {
        return '($jsonAccess as List<dynamic>).cast<$itemType>()';
      }
      return '($jsonAccess as List<dynamic>).map((e) => $itemExpr).toList()';
    }

    if (schema is ObjectSchema && schema.name != null) {
      final cls = _registry.dartClassName(schema.name!);
      return '$cls.fromJson($jsonAccess as Map<String, dynamic>)';
    }

    if (schema is ObjectSchema) {
      return 'Map<String, dynamic>.from($jsonAccess as Map)';
    }

    if (schema is EnumSchema && schema.name != null) {
      final cls = _registry.dartClassName(schema.name!);
      final castType =
          schema.enumType == 'integer'
              ? 'int'
              : schema.enumType == 'number'
              ? 'double'
              : 'String';
      return '$cls.fromJson($jsonAccess as $castType)';
    }

    if (schema is AllOfSchema && schema.name != null) {
      final cls = _registry.dartClassName(schema.name!);
      // Single-ref wrapper: resolved schema may be an enum (cast to primitive, not Map)
      if (schema.schemas.length == 1 && schema.schemas.first is EnumSchema) {
        final resolved = schema.schemas.first as EnumSchema;
        final castType =
            resolved.enumType == 'integer'
                ? 'int'
                : resolved.enumType == 'number'
                ? 'double'
                : 'String';
        return '$cls.fromJson($jsonAccess as $castType)';
      }
      return '$cls.fromJson($jsonAccess as Map<String, dynamic>)';
    }

    if (schema is OneOfSchema && schema.name != null) {
      final cls = _registry.dartClassName(schema.name!);
      return '$cls.fromJson($jsonAccess as Map<String, dynamic>)';
    }

    return '$jsonAccess as dynamic';
  }

  String _primitiveFromJson(PrimitiveSchema schema, String jsonAccess) {
    if (schema.primitiveType == 'string' && schema.format == 'date-time') {
      if (_dateTimeConverter == DateTimeConverter.timestamp) {
        return 'DateTime.fromMillisecondsSinceEpoch($jsonAccess as int)';
      }
      return 'DateTime.parse($jsonAccess as String)';
    }
    return switch (schema.primitiveType) {
      'string' => '$jsonAccess as String',
      'integer' => '$jsonAccess as int',
      'number' => '($jsonAccess as num).toDouble()',
      'boolean' => '$jsonAccess as bool',
      _ => '$jsonAccess as dynamic',
    };
  }

  /// Generates a fromJson expression for a schema used as a list item or map value.
  String _schemaFromJsonExpr(SchemaObject schema, String varName, String type) {
    if (isCyclicRef(schema)) {
      final targetClass = _registry.dartClassName(cyclicRefTargetName(schema));
      return '$targetClass.fromJson($varName as Map<String, dynamic>)';
    }
    return switch (schema) {
      PrimitiveSchema() => _primitiveFromJsonVar(schema, varName),
      ObjectSchema() when schema.name != null =>
        '${_registry.dartClassName(schema.name!)}.fromJson($varName as Map<String, dynamic>)',
      EnumSchema() when schema.name != null => _enumFromJsonVar(
        schema,
        varName,
      ),
      ArraySchema() => _nestedArrayFromJson(schema, varName),
      _ => varName, // primitive or unrecognized — emit as-is
    };
  }

  String _primitiveFromJsonVar(PrimitiveSchema schema, String varName) {
    if (schema.primitiveType == 'string' && schema.format == 'date-time') {
      if (_dateTimeConverter == DateTimeConverter.timestamp) {
        return 'DateTime.fromMillisecondsSinceEpoch($varName as int)';
      }
      return 'DateTime.parse($varName as String)';
    }
    return switch (schema.primitiveType) {
      'string' => '$varName as String',
      'integer' => '$varName as int',
      'number' => '($varName as num).toDouble()',
      'boolean' => '$varName as bool',
      _ => varName,
    };
  }

  String _enumFromJsonVar(EnumSchema schema, String varName) {
    final cls = _registry.dartClassName(schema.name!);
    final castType =
        schema.enumType == 'integer'
            ? 'int'
            : schema.enumType == 'number'
            ? 'double'
            : 'String';
    return '$cls.fromJson($varName as $castType)';
  }

  String _nestedArrayFromJson(ArraySchema schema, String varName) {
    final itemType = _dartType('', schema.items);
    final itemExpr = _schemaFromJsonExpr(schema.items, 'e', itemType);
    if (itemExpr == 'e') {
      return '($varName as List<dynamic>).cast<$itemType>()';
    }
    return '($varName as List<dynamic>).map((e) => $itemExpr).toList()';
  }

  String _toJsonExpr(_ResolvedProp p) {
    if (p.isCyclic) {
      return p.isNullable
          ? '${p.fieldName}!.toJson()'
          : '${p.fieldName}.toJson()';
    }

    final schema = p.schema;
    if (schema == null) return p.fieldName;

    if (schema is PrimitiveSchema) {
      return _primitiveToJson(schema, p.fieldName, p.isNullable);
    }

    if (schema is ArraySchema) {
      return _arrayToJsonExpr(schema, p.fieldName, p.isNullable);
    }

    if (schema is ObjectSchema && schema.name != null) {
      final access = p.isNullable ? '${p.fieldName}!' : p.fieldName;
      return '$access.toJson()';
    }

    if (schema is ObjectSchema) {
      // Map<String, dynamic>
      return p.fieldName;
    }

    if (schema is EnumSchema && schema.name != null) {
      final access = p.isNullable ? '${p.fieldName}!' : p.fieldName;
      return '$access.toJson()';
    }

    if (schema is AllOfSchema && schema.name != null) {
      final access = p.isNullable ? '${p.fieldName}!' : p.fieldName;
      return '$access.toJson()';
    }

    if (schema is OneOfSchema && schema.name != null) {
      final access = p.isNullable ? '${p.fieldName}!' : p.fieldName;
      return '$access.toJson()';
    }

    return p.fieldName;
  }

  String _primitiveToJson(
    PrimitiveSchema schema,
    String fieldName,
    bool isNullable,
  ) {
    if (schema.primitiveType == 'string' && schema.format == 'date-time') {
      final access = isNullable ? '$fieldName!' : fieldName;
      if (_dateTimeConverter == DateTimeConverter.timestamp) {
        return '$access.millisecondsSinceEpoch';
      }
      return '$access.toIso8601String()';
    }
    // Primitives serialize natively
    return fieldName;
  }

  String _arrayToJsonExpr(
    ArraySchema schema,
    String fieldName,
    bool isNullable,
  ) {
    final access = isNullable ? '$fieldName!' : fieldName;
    if (_isGeneratedType(schema.items)) {
      return '$access.map((e) => e.toJson()).toList()';
    }
    if (schema.items is PrimitiveSchema) {
      final prim = schema.items as PrimitiveSchema;
      if (prim.primitiveType == 'string' && prim.format == 'date-time') {
        if (_dateTimeConverter == DateTimeConverter.timestamp) {
          return '$access.map((e) => e.millisecondsSinceEpoch).toList()';
        }
        return '$access.map((e) => e.toIso8601String()).toList()';
      }
    }
    // Primitive arrays: JSON serializable natively
    return fieldName;
  }

  // ---------------------------------------------------------------------------
  // Const-eligibility check
  // ---------------------------------------------------------------------------

  bool _isConstEligible(List<_ResolvedProp> props) {
    for (final p in props) {
      // DateTime is not const-eligible
      if (p.isDateTime) return false;
      // List and Map are not const-eligible
      if (p.isListType || p.isMapType) return false;
      // CyclicRef is not const-eligible
      if (p.isCyclic) return false;
      // Nested ObjectSchema is not const-eligible
      if (p.schema is ObjectSchema) return false;
      // ArraySchema is not const-eligible
      if (p.schema is ArraySchema) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Enum identifier sanitization
  // ---------------------------------------------------------------------------

  String _sanitizeEnumIdentifier(String wire) {
    // Step 1: treat as string
    var s = wire;

    // Step 2: split on non-alphanumeric boundaries, then on camelCase boundaries
    final rawWords = s.split(RegExp(r'[^a-zA-Z0-9]+'));
    final words =
        rawWords
            .where((w) => w.isNotEmpty)
            .expand((w) => w.split(RegExp(r'(?<=[a-z])(?=[A-Z])')))
            .toList();
    final nonEmpty = words.where((w) => w.isNotEmpty).toList();

    if (nonEmpty.isEmpty) {
      s = 'enumEmpty';
    } else {
      // camelCase the segments: first lowercase, rest capitalized
      final first = nonEmpty.first.toLowerCase();
      final rest =
          nonEmpty
              .skip(1)
              .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
              .join();
      s = '$first$rest';

      // Handle SCREAMING_SNAKE: if original was all caps word, result is lowercase
      // e.g. IN_PROGRESS → inProgress (correct), ACTIVE → active (correct)
    }

    // Step 3: digit-leading prefix
    if (s.isNotEmpty && RegExp(r'^[0-9]').hasMatch(s)) {
      s = 'enum$s';
    }

    // Step 4: escape Dart keywords
    s = escapeKeyword(s);

    return s;
  }

  // ---------------------------------------------------------------------------
  // Filename helper
  // ---------------------------------------------------------------------------

  // [toSnakeCase] from name_converter.dart handles consecutive-capital
  // sequences (e.g. HTMLParser → html_parser) via a two-pass PascalCase-aware regex.

  // ---------------------------------------------------------------------------
  // Enum wire-value literal helper
  // ---------------------------------------------------------------------------

  Expression _wireToLiteral(String wire, String jsonType) {
    if (jsonType == 'String') return literalString(wire);
    if (jsonType == 'int') {
      final n = int.tryParse(wire);
      if (n != null) return literalNum(n);
      onWarning?.call(
        'Enum wire value "$wire" could not be parsed as int; '
        'falling back to string literal.',
      );
      return literalString(wire);
    }
    final n = double.tryParse(wire);
    if (n != null) return literalNum(n);
    onWarning?.call(
      'Enum wire value "$wire" could not be parsed as a number; '
      'falling back to string literal.',
    );
    return literalString(wire);
  }

  // ---------------------------------------------------------------------------
  // Sealed class fromJson factory builder
  // ---------------------------------------------------------------------------

  Constructor _buildSealedFromJson(
    String className,
    String? discriminatorPropertyName,
    Map<String, String> wireToVariantSpec,
  ) {
    return Constructor((ctor) {
      ctor.factory = true;
      ctor.name = 'fromJson';
      ctor.lambda = true;
      ctor.requiredParameters.add(
        Parameter((p) {
          p.name = 'json';
          p.type = refer('Map<String, dynamic>');
        }),
      );
      if (discriminatorPropertyName != null) {
        final caseLines = <String>[];
        for (final entry in wireToVariantSpec.entries) {
          final variantClass = _registry.dartClassName(entry.value);
          caseLines.add("  '${entry.key}' => $variantClass.fromJson(json),");
        }
        caseLines.add(
          "  final t => throw ArgumentError('Unknown $className discriminator value: \$t (key: $discriminatorPropertyName)'),",
        );
        ctor.lambda = false;
        ctor.body = Code(
          "if (!json.containsKey('$discriminatorPropertyName')) {\n"
          "  throw ArgumentError('Missing discriminator key \"$discriminatorPropertyName\" in JSON');\n"
          "}\n"
          "return switch (json['$discriminatorPropertyName']!.toString()) {\n${caseLines.join('\n')}\n};",
        );
      } else {
        ctor.body = Code(
          "throw UnimplementedError('$className.fromJson: no discriminator defined')",
        );
      }
    });
  }
}

// ---------------------------------------------------------------------------
// Top-level helper spec builders
// ---------------------------------------------------------------------------

/// Sentinel class for nullable-field detection in copyWith.
final _undefinedSentinelClass = Class((c) {
  c.name = '_Undefined';
  c.constructors.add(Constructor((ctor) => ctor.constant = true));
});

final _undefinedSentinelField = Field((f) {
  f.modifier = FieldModifier.constant;
  f.name = '_undefined';
  f.type = refer('_Undefined');
  f.assignment = refer('_Undefined').call([]).code;
});

/// `_listEquals<T>` helper — compares two nullable lists element-by-element.
Method _listEqualsMethod() => Method((m) {
  m.name = '_listEquals';
  m.returns = refer('bool');
  m.types.add(refer('T'));
  m.requiredParameters.addAll([
    Parameter((p) {
      p.name = 'a';
      p.type = refer('List<T>?');
    }),
    Parameter((p) {
      p.name = 'b';
      p.type = refer('List<T>?');
    }),
  ]);
  m.body = Block.of([
    ifStatement(
      refer('identical').call([refer('a'), refer('b')]),
      then: Block.of([literalTrue.returned.statement]),
    ),
    ifStatement(
      refer('a').equalTo(literalNull).or(refer('b').equalTo(literalNull)),
      then: Block.of([literalFalse.returned.statement]),
    ),
    ifStatement(
      refer('a').property('length').notEqualTo(refer('b').property('length')),
      then: Block.of([literalFalse.returned.statement]),
    ),
    forIndexStatement(
      'i',
      refer('a').property('length'),
      body: Block.of([
        ifStatement(
          refer('a').index(refer('i')).notEqualTo(refer('b').index(refer('i'))),
          then: Block.of([literalFalse.returned.statement]),
        ),
      ]),
    ),
    literalTrue.returned.statement,
  ]);
});

/// `_mapEquals<K, V>` helper — compares two nullable maps key-by-key.
Method _mapEqualsMethod() => Method((m) {
  m.name = '_mapEquals';
  m.returns = refer('bool');
  m.types.addAll([refer('K'), refer('V')]);
  m.requiredParameters.addAll([
    Parameter((p) {
      p.name = 'a';
      p.type = refer('Map<K, V>?');
    }),
    Parameter((p) {
      p.name = 'b';
      p.type = refer('Map<K, V>?');
    }),
  ]);
  m.body = Block.of([
    ifStatement(
      refer('identical').call([refer('a'), refer('b')]),
      then: Block.of([literalTrue.returned.statement]),
    ),
    ifStatement(
      refer('a').equalTo(literalNull).or(refer('b').equalTo(literalNull)),
      then: Block.of([literalFalse.returned.statement]),
    ),
    ifStatement(
      refer('a').property('length').notEqualTo(refer('b').property('length')),
      then: Block.of([literalFalse.returned.statement]),
    ),
    forEachStatement(
      'key',
      refer('a').property('keys'),
      body: Block.of([
        ifStatement(
          refer('b')
              .property('containsKey')
              .call([refer('key')])
              .negate()
              .or(
                refer('a')
                    .index(refer('key'))
                    .notEqualTo(refer('b').index(refer('key'))),
              ),
          then: Block.of([literalFalse.returned.statement]),
        ),
      ]),
    ),
    literalTrue.returned.statement,
  ]);
});

// ---------------------------------------------------------------------------
// Internal resolved-property record
// ---------------------------------------------------------------------------

final class _ResolvedProp {
  final String specName;
  final String fieldName;
  final String dartType;
  final bool isNullable;
  final bool isRequired;
  final bool isListType;
  final bool isMapType;
  final bool isCyclic;
  final String? isCyclicTarget;
  final bool isEnumType;
  final bool isPrimitive;
  final bool isDateTime;
  final bool dateTimeIsTimestamp;
  final bool isListOfGenerated;
  final bool isMapOfGenerated;
  final SchemaObject? schema;

  const _ResolvedProp({
    required this.specName,
    required this.fieldName,
    required this.dartType,
    required this.isNullable,
    required this.isRequired,
    required this.isListType,
    required this.isMapType,
    required this.isCyclic,
    required this.isCyclicTarget,
    required this.isEnumType,
    required this.isPrimitive,
    required this.isDateTime,
    required this.dateTimeIsTimestamp,
    required this.isListOfGenerated,
    required this.isMapOfGenerated,
    required this.schema,
  });
}
