import 'package:code_builder/code_builder.dart';

import '../date_time_converter.dart';
import '../layout/model_layout.dart';
import '../layout/one_of_plan.dart';
import '../model/openapi_parse_exception.dart';
import '../model/schema_object.dart';
import '../model/spec_document.dart';
import '../name_registry/keyword_escaper.dart';
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
/// final generator = ModelGenerator(registry, layout, DateTimeConverter.iso8601);
/// final files = generator.generate(document);
/// ```
final class ModelGenerator {
  final NameRegistry _registry;
  final DateTimeConverter _dateTimeConverter;

  /// Optional warning sink for enum value sanitization and other advisory
  /// messages. Callers should route this to `log.warning` in the builder context.
  final void Function(String)? onWarning;

  /// Where each schema is declared. Built once per document by the caller,
  /// like [NameRegistry].
  final ModelLayout _layout;

  const ModelGenerator(
    this._registry,
    this._layout,
    this._dateTimeConverter, {
    this.onWarning,
  });

  /// Generates one Dart source file per model file in [document].
  ///
  /// Most schemas get a file of their own. `oneOf` wrappers and the component
  /// schemas they reference through `$ref` share a file — see [ModelLayout] —
  /// because Dart only lets a `sealed` type be implemented from inside its own
  /// library. Sharing the library is what keeps the wrapper exhaustive while
  /// the branches stay standalone, reusable classes.
  ///
  /// Returns `Map<String, String>` where keys are `'models/<name>.dart'`
  /// and values are formatted Dart source strings.
  Map<String, String> generate(SpecDocument document) {
    final result = <String, String>{};
    for (final file in _layout.files) {
      final body = <Spec>[];
      final imports = <String>{};
      var needsUndefined = false;
      var needsListEquals = false;
      var needsMapEquals = false;

      for (final specName in _layout.membersOf(file)) {
        // Non-null: the layout is built from `document.schemas`, so every
        // member name it lists is a key of that map.
        final schema = document.schemas[specName]!;
        final specs = _specsFor(
          specName,
          schema,
          file,
          _layout.unionsImplementedBy(specName),
        );
        body.addAll(specs.body);
        imports.addAll(specs.imports);
        needsUndefined = needsUndefined || specs.needsUndefined;
        needsListEquals = needsListEquals || specs.needsListEquals;
        needsMapEquals = needsMapEquals || specs.needsMapEquals;
      }
      if (body.isEmpty) continue;

      result['models/$file'] = emitLibrary(
        Library((lib) {
          for (final imp in imports.toList()..sort()) {
            lib.directives.add(Directive.import(imp));
          }
          if (needsUndefined) {
            lib.body.add(_undefinedSentinelClass);
            lib.body.add(_undefinedSentinelField);
          }
          if (needsListEquals) lib.body.add(_listEqualsMethod());
          if (needsMapEquals) lib.body.add(_mapEqualsMethod());
          lib.body.addAll(body);
        }),
      );
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Top-level dispatch
  // ---------------------------------------------------------------------------

  _SchemaSpecs _specsFor(
    String specName,
    SchemaObject schema,
    String selfFile,
    List<String> implementsClauses,
  ) {
    // _CyclicRefSchema is private to schema_object.dart; use isCyclicRef() to
    // detect it before entering the switch. A top-level cyclic-ref sentinel
    // means the schema IS the cycle root — skip emission but warn the user.
    if (isCyclicRef(schema)) {
      final targetName = cyclicRefTargetName(schema);
      onWarning?.call(
        'Cyclic reference detected for type "$targetName" — skipping top-level '
        'file emission for "$specName". The type will be referenced as a late field.',
      );
      return const _SchemaSpecs();
    }
    return switch (schema) {
      ObjectSchema() => _objectSpecs(
        specName,
        schema,
        selfFile,
        implementsClauses: implementsClauses,
      ),
      EnumSchema() => _enumSpecs(specName, schema),
      PrimitiveSchema() => _primitiveSpecs(specName, schema),
      ArraySchema() => _arraySpecs(specName, schema, selfFile),
      AllOfSchema() => _allOfSpecs(
        specName,
        schema,
        selfFile,
        implementsClauses: implementsClauses,
      ),
      OneOfSchema() => _oneOfSpecs(
        specName,
        schema,
        selfFile,
        implementsClauses: implementsClauses,
      ),
      NullSchema() => const _SchemaSpecs(), // top-level null schema: skip
      // Unreachable: _CyclicRefSchema is caught above by isCyclicRef() guard.
      _ => const _SchemaSpecs(),
    };
  }

  // ---------------------------------------------------------------------------
  // ObjectSchema emission
  // ---------------------------------------------------------------------------

  /// Collects import paths for all schema types referenced in [props].
  ///
  /// Returns a sorted list of relative import strings of the form
  /// `'<snake_name>.dart'` (relative to the `models/` directory),
  /// excluding [selfFile] (to avoid self-imports).
  ///
  /// [selfFile] is the file being generated, e.g. `'user.dart'`. Target files
  /// come from [ModelLayout], never from the class name — a clustered schema
  /// does not live in the file its own name would suggest.
  List<String> _collectImportsForProps(
    String selfFile,
    List<_ResolvedProp> props,
  ) {
    final imports = <String>{};
    for (final p in props) {
      if (p.isCyclic) {
        final targetSpecName = p.cyclicTargetSpecName;
        if (targetSpecName != null) {
          _addImportForName(selfFile, targetSpecName, imports);
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
      _addImportForName(selfFile, cyclicRefTargetName(schema), imports);
      return;
    }
    final name = switch (schema) {
      EnumSchema() ||
      ObjectSchema() ||
      AllOfSchema() ||
      OneOfSchema() => schema.name,
      _ => null, // primitives and anonymous objects need no import
    };
    if (name != null) {
      _addImportForName(selfFile, name, imports);
      return;
    }
    if (schema is ArraySchema) {
      _addImportForSchema(selfFile, schema.items, imports);
    }
  }

  /// Adds the import for the file declaring [specName], unless that file is
  /// [selfFile] — which is the case for every member of the same cluster.
  void _addImportForName(
    String selfFile,
    String specName,
    Set<String> imports,
  ) {
    final resolved = _layout.resolveFile(specName);
    if (resolved != selfFile) imports.add(resolved);
  }

  _SchemaSpecs _objectSpecs(
    String specName,
    ObjectSchema schema,
    String selfFile, {
    String? extendsClause,
    List<String> implementsClauses = const [],
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
        cyclicTargetSpecName: null,
        isEnumType: false,
        isPrimitive: false,
        isDateTime: false,
        dateTimeIsTimestamp: false,
        isListOfGenerated: false,
        isMapOfGenerated: apSchema != null && _isGeneratedType(apSchema),
        schema: apSchema,
      );
    }

    // Merge and sort all props alphabetically by fieldName
    final allProps = [
      ...resolvedProps,
      if (additionalPropEntry != null) additionalPropEntry,
    ]..sort((a, b) => a.fieldName.compareTo(b.fieldName));

    final needsUndefined = allProps.any((p) => p.isNullable);

    return _SchemaSpecs(
      body: [
        _buildObjectClass(
          className: className,
          props: allProps,
          isConstEligible: _isConstEligible(allProps),
          extendsClause: extendsClause,
          implementsClauses: implementsClauses,
        ),
      ],
      imports: _collectImportsForProps(selfFile, allProps).toSet(),
      needsUndefined: needsUndefined,
      needsListEquals: allProps.any((p) => p.isListType),
      needsMapEquals: allProps.any((p) => p.isMapType),
    );
  }

  Class _buildObjectClass({
    required String className,
    required List<_ResolvedProp> props,
    required bool isConstEligible,
    String? extendsClause,
    List<String> implementsClauses = const [],
  }) {
    return Class((c) {
      c.modifier = ClassModifier.final$;
      c.name = className;
      if (extendsClause != null) c.extend = refer(extendsClause);
      for (final iface in implementsClauses) {
        c.implements.add(refer(iface));
      }

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
      c.methods.add(
        _buildToJsonMethod(
          className,
          props,
          isOverride: extendsClause != null || implementsClauses.isNotEmpty,
        ),
      );

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
    List<_ResolvedProp> props, {
    required bool isOverride,
  }) {
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
      if (isOverride) m.annotations.add(refer('override'));
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

  _SchemaSpecs _enumSpecs(String specName, EnumSchema schema) {
    final className = _registry.dartClassName(specName);

    // Sanitize and sort enum values alphabetically by Dart identifier
    final entries = <({String wire, String dart})>[];
    for (final wireValue in schema.values) {
      final wire = wireValue.toString();
      final dart = _sanitizeEnumIdentifier(wire);
      if (dart != wire) {
        onWarning?.call(
          'Enum value sanitized: "$wire" \u2192 "$dart" in $specName',
        );
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

    return _SchemaSpecs(
      body: [
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
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // PrimitiveSchema emission (typedef)
  // ---------------------------------------------------------------------------

  _SchemaSpecs _primitiveSpecs(String specName, PrimitiveSchema schema) {
    final className = _registry.dartClassName(specName);
    final dartType = _primitiveType(schema.primitiveType, schema.format);
    return _SchemaSpecs(
      body: [
        TypeDef((t) {
          t.name = className;
          t.definition = refer(dartType);
        }),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // ArraySchema emission (typedef)
  // ---------------------------------------------------------------------------

  _SchemaSpecs _arraySpecs(
    String specName,
    ArraySchema schema,
    String selfFile,
  ) {
    final className = _registry.dartClassName(specName);
    final itemType = _dartType(specName, schema.items);
    final imports = <String>{};
    _addImportForSchema(selfFile, schema.items, imports);
    return _SchemaSpecs(
      body: [
        TypeDef((t) {
          t.name = className;
          t.definition = refer('List<$itemType>');
        }),
      ],
      imports: imports,
    );
  }

  // ---------------------------------------------------------------------------
  // AllOfSchema emission (flat merge)
  // ---------------------------------------------------------------------------

  _SchemaSpecs _allOfSpecs(
    String specName,
    AllOfSchema schema,
    String selfFile, {
    List<String> implementsClauses = const [],
  }) {
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

    return _objectSpecs(
      specName,
      syntheticSchema,
      selfFile,
      implementsClauses: implementsClauses,
    );
  }

  // ---------------------------------------------------------------------------
  // OneOfSchema emission (sealed class)
  // ---------------------------------------------------------------------------

  _SchemaSpecs _oneOfSpecs(
    String specName,
    OneOfSchema schema,
    String selfFile, {
    List<String> implementsClauses = const [],
  }) {
    final className = _registry.dartClassName(specName);
    final imports = <String>{};
    final body = <Spec>[];
    var needsUndefined = false;
    var needsListEquals = false;
    var needsMapEquals = false;

    // Branches were classified once, for the whole document, by [OneOfPlan]:
    //  - [ReusedRefBranch]    a $ref to a class-shaped component: reused, and
    //                         never redeclared here;
    //  - [InlineObjectBranch] an anonymous inline object: emitted as a
    //                         subclass in this file;
    //  - [ValueBranch]        anything else (array, primitive, enum): emitted
    //                         as a class holding the decoded value, since
    //                         those types cannot implement the wrapper;
    //  - [SkippedBranch]      a $ref cycle or an unresolvable target: dropped
    //                         with an advisory warning.
    final arms = <_OneOfArm>[];
    final inlineVariants = <({String specName, ObjectSchema schema})>[];
    final valueVariants = <({String specName, SchemaObject schema})>[];

    for (final branch in _layout.oneOfPlan.branchesOf(specName)) {
      switch (branch) {
        case SkippedBranch():
          onWarning?.call(branch.reason);
        case ReusedRefBranch():
          _addImportForName(selfFile, branch.specName, imports);
          final shape = _schemaShape(branch.schema);
          arms.add((
            specName: branch.specName,
            className: _registry.dartClassName(branch.specName),
            isMapShaped: true,
            requiredCount: shape.required,
            propertyCount: shape.total,
          ));
        case InlineObjectBranch():
          inlineVariants.add((
            specName: branch.specName,
            schema: branch.schema,
          ));
          final shape = _schemaShape(branch.schema);
          arms.add((
            specName: branch.specName,
            className: _registry.dartClassName(branch.specName),
            isMapShaped: true,
            requiredCount: shape.required,
            propertyCount: shape.total,
          ));
        case ValueBranch():
          valueVariants.add((specName: branch.specName, schema: branch.schema));
          arms.add((
            specName: branch.specName,
            className: _registry.dartClassName(branch.specName),
            isMapShaped: false,
            requiredCount: 0,
            propertyCount: 0,
          ));
      }
    }

    if (arms.isEmpty) {
      onWarning?.call(
        'oneOf "$specName" has no usable variant; emitting an empty sealed class.',
      );
    }

    // A union with a non-object branch cannot promise a JSON object, so its
    // toJson/fromJson widen to Object?. Unions of objects keep the narrower
    // Map<String, dynamic> signature.
    final isPolymorphic = _layout.oneOfPlan.isPolymorphic(specName);

    // Discriminator mapping: wire value → variant spec name.
    final Map<String, String> wireToVariantSpec;
    if (schema.discriminatorMapping != null) {
      wireToVariantSpec = {
        for (final e in schema.discriminatorMapping!.entries)
          e.key: e.value.split('/').last,
      };
    } else {
      wireToVariantSpec = {for (final a in arms) a.specName: a.specName};
    }

    body.add(
      Class((c) {
        c.sealed = true;
        c.name = className;
        if (schema.discriminatorPropertyName == null && arms.isNotEmpty) {
          c.docs.addAll([
            '/// A `oneOf` union with no `discriminator`.',
            '///',
            '/// [$className.fromJson] guesses the variant from the shape of the',
            '/// payload; read its documentation before relying on the result.',
          ]);
        }
        for (final iface in implementsClauses) {
          c.implements.add(refer(iface));
        }
        c.constructors.add(Constructor((ctor) => ctor.constant = true));
        c.constructors.add(
          _buildSealedFromJson(
            specName,
            className,
            schema.discriminatorPropertyName,
            wireToVariantSpec,
            arms,
            isPolymorphic: isPolymorphic,
          ),
        );
        c.methods.add(
          Method((m) {
            m.name = 'toJson';
            m.returns = refer(
              isPolymorphic ? 'Object?' : 'Map<String, dynamic>',
            );
            // no body = abstract method
          }),
        );
      }),
    );

    // Inline anonymous variants: full subclasses, as before.
    final inlineProps = <({String specName, List<_ResolvedProp> props})>[
      for (final v in inlineVariants)
        (specName: v.specName, props: _resolveProperties(v.specName, v.schema)),
    ];
    for (final v in inlineProps) {
      if (v.props.any((p) => p.isNullable)) needsUndefined = true;
      if (v.props.any((p) => p.isListType)) needsListEquals = true;
      if (v.props.any((p) => p.isMapType)) needsMapEquals = true;
      imports.addAll(_collectImportsForProps(selfFile, v.props));
    }
    for (final v in inlineProps) {
      body.add(
        _buildObjectClass(
          className: _registry.dartClassName(v.specName),
          props: v.props,
          isConstEligible: _isConstEligible(v.props),
          extendsClause: className,
        ),
      );
    }

    // Value-holding variants for branches that cannot implement the wrapper.
    for (final v in valueVariants) {
      final valueProp = _resolveValueProp(specName, v.schema);
      if (valueProp.isListType) needsListEquals = true;
      _addImportForSchema(selfFile, v.schema, imports);
      body.add(
        _buildValueVariantClass(
          className: _registry.dartClassName(v.specName),
          wrapperClassName: className,
          valueProp: valueProp,
          isPolymorphic: isPolymorphic,
        ),
      );
    }

    return _SchemaSpecs(
      body: body,
      imports: imports,
      needsUndefined: needsUndefined,
      needsListEquals: needsListEquals,
      needsMapEquals: needsMapEquals,
    );
  }

  /// Number of required and declared properties of a schema, used to order
  /// the variants a discriminator-less `fromJson` tries.
  ({int required, int total}) _schemaShape(SchemaObject schema) {
    if (schema is ObjectSchema) {
      return (
        required: schema.required.length,
        total: schema.properties.length,
      );
    }
    if (schema is AllOfSchema) {
      var req = 0;
      var total = 0;
      for (final member in schema.schemas) {
        final shape = _schemaShape(member);
        req += shape.required;
        total += shape.total;
      }
      return (required: req, total: total);
    }
    return (required: 0, total: 0);
  }

  /// Resolves a whole schema as a single `value` field — used by the classes
  /// that hold a non-object `oneOf` branch.
  _ResolvedProp _resolveValueProp(String ownerSpecName, SchemaObject schema) {
    final dartType = _dartType(ownerSpecName, schema);
    final isListType = dartType.startsWith('List<');
    return _ResolvedProp(
      specName: 'value',
      fieldName: 'value',
      dartType: dartType,
      isNullable: false,
      isRequired: true,
      isListType: isListType,
      isMapType: dartType.startsWith('Map<'),
      isCyclic: false,
      isCyclicTarget: null,
      cyclicTargetSpecName: null,
      isEnumType: schema is EnumSchema,
      isPrimitive: schema is PrimitiveSchema,
      isDateTime: schema is PrimitiveSchema && schema.format == 'date-time',
      dateTimeIsTimestamp:
          schema is PrimitiveSchema &&
          schema.format == 'date-time' &&
          _dateTimeConverter == DateTimeConverter.timestamp,
      isListOfGenerated:
          isListType && schema is ArraySchema && _isGeneratedType(schema.items),
      isMapOfGenerated: false,
      schema: schema,
    );
  }

  Class _buildValueVariantClass({
    required String className,
    required String wrapperClassName,
    required _ResolvedProp valueProp,
    required bool isPolymorphic,
  }) {
    final decode = _fromJsonExpr(valueProp, 'json', nullable: false);
    final encode = _toJsonExpr(valueProp);
    return Class((c) {
      c.modifier = ClassModifier.final$;
      c.name = className;
      c.extend = refer(wrapperClassName);
      c.fields.add(
        Field((f) {
          f.modifier = FieldModifier.final$;
          f.name = 'value';
          f.type = refer(valueProp.dartType);
        }),
      );
      c.constructors.add(
        Constructor((ctor) {
          ctor.constant = true;
          ctor.requiredParameters.add(
            Parameter((p) {
              p.name = 'value';
              p.toThis = true;
            }),
          );
        }),
      );
      c.constructors.add(
        Constructor((ctor) {
          ctor.factory = true;
          ctor.name = 'fromJson';
          ctor.lambda = true;
          ctor.requiredParameters.add(
            Parameter((p) {
              p.name = 'json';
              p.type = refer('Object?');
            }),
          );
          ctor.body = Code('$className($decode)');
        }),
      );
      c.methods.add(
        Method((m) {
          m.annotations.add(refer('override'));
          m.name = 'toJson';
          m.returns = refer(isPolymorphic ? 'Object?' : 'Map<String, dynamic>');
          m.lambda = true;
          m.body = Code(encode);
        }),
      );
      c.methods.add(
        Method((m) {
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
          final cmp =
              valueProp.isListType
                  ? '_listEquals(value, other.value)'
                  : 'value == other.value';
          m.body = Code(
            'identical(this, other) || other is $className && $cmp',
          );
        }),
      );
      c.methods.add(
        Method((m) {
          m.annotations.add(refer('override'));
          m.name = 'hashCode';
          m.type = MethodType.getter;
          m.returns = refer('int');
          m.lambda = true;
          m.body = Code(
            valueProp.isListType ? 'Object.hashAll(value)' : 'value.hashCode',
          );
        }),
      );
    });
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
            cyclicTargetSpecName: targetName,
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
          cyclicTargetSpecName: null,
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

  /// Dart class name for a `discriminator.mapping` target that is not itself a
  /// branch of this `oneOf`.
  ///
  /// A mapping pointing at a schema the document never declares is a spec
  /// error, and has to read as one: without this the lookup would surface the
  /// registry's internal [StateError] and abort the build with a message about
  /// the generator's own state instead of the user's spec.
  String _mappingTargetClassName(
    String specName,
    String wireValue,
    String targetSpecName,
  ) {
    try {
      return _registry.dartClassName(targetSpecName);
    } on StateError {
      throw OpenApiParseException(
        'Discriminator mapping of "$specName" maps "$wireValue" to '
        '"$targetSpecName", which is not a schema declared in this document. '
        'Point the mapping at a declared schema or remove the entry.',
        jsonPointer:
            '#/components/schemas/$specName/discriminator/mapping/$wireValue',
      );
    }
  }

  Constructor _buildSealedFromJson(
    String specName,
    String className,
    String? discriminatorPropertyName,
    Map<String, String> wireToVariantSpec,
    List<_OneOfArm> arms, {
    required bool isPolymorphic,
  }) {
    final classNameBySpec = {for (final a in arms) a.specName: a.className};
    final jsonType = isPolymorphic ? 'Object?' : 'Map<String, dynamic>';

    return Constructor((ctor) {
      ctor.factory = true;
      ctor.name = 'fromJson';
      ctor.requiredParameters.add(
        Parameter((p) {
          p.name = 'json';
          p.type = refer(jsonType);
        }),
      );

      if (discriminatorPropertyName != null) {
        final caseLines = <String>[];
        for (final entry in wireToVariantSpec.entries) {
          final variantClass =
              classNameBySpec[entry.value] ??
              _mappingTargetClassName(specName, entry.key, entry.value);
          caseLines.add("  '${entry.key}' => $variantClass.fromJson(json),");
        }
        caseLines.add(
          "  final t => throw ArgumentError('Unknown $className discriminator value: \$t (key: $discriminatorPropertyName)'),",
        );
        final buffer = StringBuffer();
        if (isPolymorphic) {
          buffer.writeln(
            "if (json is! Map<String, dynamic>) {\n"
            "  throw ArgumentError('Expected a JSON object for $className, got \${json.runtimeType}');\n"
            "}",
          );
        }
        buffer.writeln(
          "if (!json.containsKey('$discriminatorPropertyName')) {\n"
          "  throw ArgumentError('Missing discriminator key \"$discriminatorPropertyName\" in JSON');\n"
          "}",
        );
        buffer.write(
          "return switch (json['$discriminatorPropertyName']!.toString()) {\n${caseLines.join('\n')}\n};",
        );
        ctor.body = Code(buffer.toString());
        return;
      }

      // No discriminator: try the variants and keep the first that decodes.
      // Order is by descending specificity — most required properties first,
      // then most declared properties, then spec order. A payload that
      // satisfies both a narrow and a wide variant belongs to the wide one:
      // trying the narrow one first would swallow every superset of it.
      // See [_sortArmsByShape].
      final ordered = [...arms];
      _sortArmsByShape(ordered);
      // The consumer of the generated client never reads this file, so the
      // heuristic and its failure mode have to travel with the code.
      ctor.docs.addAll([
        '/// Decodes [json] into one of the variants of [$className].',
        '///',
        '/// This union declares no `discriminator`, so the variant is inferred',
        '/// from the payload: each candidate is tried in turn and the first one',
        '/// that decodes wins. The order is fixed at generation time, from the',
        '/// most specific shape to the least:',
        '///',
        for (var i = 0; i < ordered.length; i++)
          '/// ${i + 1}. [${ordered[i].className}]',
        '///',
        '/// Every error raised while trying a variant is swallowed, including a',
        '/// genuine failure deep inside a nested `fromJson`. A payload that no',
        '/// variant accepts surfaces as a [FormatException] here, with no trace',
        '/// of why each candidate was rejected — and a payload that two variants',
        '/// both accept is resolved by the order above, not by the server\'s',
        '/// intent.',
        '///',
        '/// Add `discriminator.propertyName` to this schema in the OpenAPI',
        '/// document to replace the whole heuristic with an exact lookup.',
      ]);
      final buffer = StringBuffer();
      for (final arm in ordered) {
        if (arm.isMapShaped && isPolymorphic) {
          buffer.writeln(
            'if (json is Map<String, dynamic>) {\n'
            '  try {\n'
            '    return ${arm.className}.fromJson(json);\n'
            '  } catch (_) {}\n'
            '}',
          );
        } else {
          buffer.writeln(
            'try {\n'
            '  return ${arm.className}.fromJson(json);\n'
            '} catch (_) {}',
          );
        }
      }
      buffer.write(
        "throw FormatException('$className.fromJson: no variant matched the payload');",
      );
      ctor.body = Code(buffer.toString());
    });
  }
}

/// Sorts [arms] into the order a discriminator-less `fromJson` should try them:
/// most specific first.
///
/// "Specificity" is the shape of the variant's JSON object: first its number of
/// **required** properties, then its number of declared properties. Value-held
/// branches (arrays, primitives, enums) count as zero on both and therefore
/// sort last, which is what we want — they accept the payloads no object
/// variant claimed.
///
/// The order must be **descending** because the generated dispatch keeps the
/// first variant that decodes without throwing, and a narrow variant accepts
/// every payload of a wider one: `Customer{id}` ⊂ `Driver{id, license}`, so
/// trying `Customer` first would swallow every `Driver`. Descending order makes
/// the wider variant win, which is the only choice that can ever be right when
/// one variant's required set is a subset of another's.
///
/// The tie-break is the arm's original index, i.e. the order the variants are
/// declared in the spec. It has to be explicit: [List.sort] is not stable, so
/// without it two same-shaped variants could swap between runs and change the
/// generated file for an unchanged spec.
///
/// Cases that stay ambiguous by design: two variants with the same required
/// set and the same property count are decided by declaration order alone, and
/// a payload carrying extra unknown keys still matches whichever variant
/// tolerates it first. Both are unresolvable from the shape of the schema — the
/// spec-level fix is `discriminator.propertyName`, and the generated dartdoc
/// says so.
void _sortArmsByShape(List<_OneOfArm> arms) {
  final indexed = [
    for (var i = 0; i < arms.length; i++) (index: i, arm: arms[i]),
  ];
  indexed.sort((a, b) {
    final byRequired = b.arm.requiredCount.compareTo(a.arm.requiredCount);
    if (byRequired != 0) return byRequired;
    final byTotal = b.arm.propertyCount.compareTo(a.arm.propertyCount);
    if (byTotal != 0) return byTotal;
    return a.index.compareTo(b.index);
  });
  for (var i = 0; i < arms.length; i++) {
    arms[i] = indexed[i].arm;
  }
}

/// One branch of a `oneOf`, as seen by the generated `fromJson` dispatch.
///
/// [isMapShaped] is false for branches held by a generated value class
/// (arrays, primitives, enums) — those decode from a non-object payload.
typedef _OneOfArm =
    ({
      String specName,
      String className,
      bool isMapShaped,
      int requiredCount,
      int propertyCount,
    });

/// Everything one schema contributes to the file it is emitted in.
///
/// A file may hold several schemas (a `oneOf` cluster), so the top-level
/// helpers are requested here and emitted once per file by [ModelGenerator].
final class _SchemaSpecs {
  final List<Spec> body;
  final Set<String> imports;
  final bool needsUndefined;
  final bool needsListEquals;
  final bool needsMapEquals;

  const _SchemaSpecs({
    this.body = const [],
    this.imports = const {},
    this.needsUndefined = false,
    this.needsListEquals = false,
    this.needsMapEquals = false,
  });
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

  /// Spec name (not Dart class name) of a cyclic target, for [ModelLayout].
  final String? cyclicTargetSpecName;
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
    required this.cyclicTargetSpecName,
    required this.isEnumType,
    required this.isPrimitive,
    required this.isDateTime,
    required this.dateTimeIsTimestamp,
    required this.isListOfGenerated,
    required this.isMapOfGenerated,
    required this.schema,
  });
}
