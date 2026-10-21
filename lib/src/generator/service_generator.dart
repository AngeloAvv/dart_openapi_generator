import 'package:code_builder/code_builder.dart';

import '../date_time_converter.dart';
import '../layout/model_layout.dart';
import '../model/media_type.dart';
import '../model/schema_object.dart';
import '../model/spec_document.dart';
import '../name_registry/keyword_escaper.dart';
import '../name_registry/name_converter.dart';
import '../name_registry/name_registry.dart';
import '../parser/operation_naming.dart';
import 'code_builder_emitter.dart';
import 'code_builder_helpers.dart';
import 'form_body.dart';

/// Converts [SpecDocument.operations] (grouped by tag) into a map of
/// filename → Dart source for one [{Tag}Api] class per tag.
///
/// Key format: `'services/<snake_case_tag>_api.dart'`
///
/// Usage:
/// ```dart
/// final generator = ServiceGenerator(registry, layout);
/// final files = generator.generate(document);
/// ```
final class ServiceGenerator {
  final NameRegistry _registry;

  /// Optional warning sink for cookie-param skips, no-2xx operations,
  /// non-200 2xx fallbacks, untyped request bodies and responses, form
  /// encodings that cannot be honoured, and 3.2 additionalMethod stubs.
  /// Callers should route this to `log.warning` in the builder context.
  final void Function(String)? onWarning;

  /// How `DateTime` properties of a `multipart/form-data` body are written,
  /// matching the `toJson()` of the models.
  final DateTimeConverter _dateTimeConverter;

  static const _getLikeMethods = {'get', 'head', 'options'};
  static const _deleteLikeMethods = {'delete'};
  static const _namedDioMethods = {
    'get',
    'post',
    'put',
    'patch',
    'delete',
    'head',
  };

  /// Where each model is declared, and which unions are polymorphic. Built
  /// once per document by the caller, like [NameRegistry].
  final ModelLayout _layout;

  const ServiceGenerator(
    this._registry,
    this._layout, {
    this.onWarning,
    DateTimeConverter dateTimeConverter = DateTimeConverter.iso8601,
  }) : _dateTimeConverter = dateTimeConverter;

  /// Generates one Dart source file per tag in [document].
  ///
  /// Operations are grouped by first tag (or 'Default' for untagged ops).
  /// Tags and methods within each file are sorted alphabetically (D2).
  ///
  /// Returns `Map<String, String>` where keys are `'services/<tag>_api.dart'`
  /// and values are Dart source strings.
  Map<String, String> generate(SpecDocument document) {
    // Group operations by effective tag: tags[0] or 'Default'
    final tagGroups = <String, List<OperationItem>>{};
    for (final op in document.operations) {
      final tag = op.tags.isEmpty ? 'Default' : op.tags[0];
      tagGroups.putIfAbsent(tag, () => []).add(op);
    }

    // Sort tag names alphabetically
    final sortedTags = tagGroups.keys.toList()..sort();

    // Operations whose primary response is a non-200 2xx. Collected per
    // generate() call — this class is const-constructed and immutable, so the
    // accumulator is a local threaded through the builders — and reported as a
    // single aggregated warning instead of one line per operation.
    final non200Primary = <String>[];
    // Same for operations whose primary response is not JSON, and is returned
    // as text or bytes.
    final untypedPrimary = <String>[];

    final result = <String, String>{};
    for (final tag in sortedTags) {
      final ops = tagGroups[tag]!;
      final fileName = _tagToFileName(tag);
      final source = _emitServiceFile(tag, ops, non200Primary, untypedPrimary);
      result[fileName] = source;
    }

    if (non200Primary.isNotEmpty) {
      onWarning?.call(
        '${non200Primary.length} operation(s) use a non-200 2xx response as '
        'the primary response: ${non200Primary.join(', ')}.',
      );
    }
    if (untypedPrimary.isNotEmpty) {
      onWarning?.call(
        '${untypedPrimary.length} operation(s) have a primary response that is '
        'not JSON, returned undecoded: ${untypedPrimary.join(', ')}.',
      );
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Library builder
  // ---------------------------------------------------------------------------

  String _emitServiceFile(
    String tag,
    List<OperationItem> ops,
    List<String> non200Primary,
    List<String> untypedPrimary,
  ) {
    final className = _tagToClassName(tag);
    final bodyPlans = {for (final op in ops) op: _planBody(op)};
    final imports = _collectImports(ops, bodyPlans);
    final dartImports = {
      if (bodyPlans.values.any((p) => p.needsJsonEncode)) 'dart:convert',
      if (ops.any((op) => _responseKind(op) == _ResponseKind.bytes))
        'dart:typed_data',
    };

    // Sort ops alphabetically by derived method name
    final sortedOps =
        ops.toList()..sort((a, b) => _methodName(a).compareTo(_methodName(b)));

    return emitLibrary(
      Library((lib) {
        for (final imp in dartImports.toList()..sort()) {
          lib.directives.add(Directive.import(imp));
        }
        lib.directives.add(Directive.import('package:dio/dio.dart'));
        for (final imp in imports) {
          lib.directives.add(Directive.import(imp));
        }

        lib.body.add(
          Class((c) {
            c.name = className;
            c.fields.add(
              Field((f) {
                f.name = '_dio';
                f.type = refer('Dio');
                f.modifier = FieldModifier.final$;
              }),
            );
            c.constructors.add(
              Constructor((ctor) {
                ctor.constant = true;
                ctor.requiredParameters.add(
                  Parameter((p) {
                    p.name = '_dio';
                    p.toThis = true;
                  }),
                );
              }),
            );

            for (final op in sortedOps) {
              c.methods.add(
                _buildMethod(op, bodyPlans[op]!, non200Primary, untypedPrimary),
              );
            }

            // Emit additionalMethod stubs after all standard methods
            c.methods.addAll(_buildAdditionalMethods(sortedOps));
          }),
        );
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // Import collection
  // ---------------------------------------------------------------------------

  Set<String> _collectModelImports(
    List<OperationItem> ops,
    Map<OperationItem, _BodyPlan> bodyPlans,
  ) {
    final importSet = <String>{};

    for (final op in ops) {
      // Return type imports
      final primary = _selectPrimary2xx(op.responses);
      if (primary != null && primary.schema != null) {
        final schema = primary.schema!;
        _addSchemaImports(schema, op, importSet);
      }

      // Request body imports: only for a body typed with its schema.
      final bodySchema = op.requestBody?.schema;
      if (bodySchema != null && bodyPlans[op]!.isTyped) {
        _addSingleSchemaImport(
          bodySchema,
          op,
          isRequest: true,
          importSet: importSet,
        );
      }

      // Parameter imports (enum/object/allOf types used in path/query/header params)
      for (final param in op.parameters) {
        _addParamSchemaImport(param.schema, importSet);
      }
    }

    return importSet;
  }

  /// Adds an import for a parameter schema if it resolves to a named generated type.
  ///
  /// Handles anonymous allOf wrappers (OpenAPI 3.0 nullable pattern) by
  /// inspecting the first schema in the list.
  void _addParamSchemaImport(SchemaObject schema, Set<String> importSet) {
    final effective = _effectiveSchema(schema);
    if (effective.name == null) return;
    // PrimitiveSchema aliases (e.g. LocalDate → String) have no generated model file.
    if (effective is PrimitiveSchema) return;
    final import = _modelImport(effective.name!);
    if (import != null) importSet.add(import);
  }

  /// Import path for the file declaring [specName], or null when the schema
  /// has no generated model file.
  ///
  /// The file comes from [ModelLayout]: a `oneOf` branch is declared in its
  /// wrapper's library, not in a file named after itself.
  String? _modelImport(String specName) {
    try {
      _registry.dartClassName(specName);
    } on StateError {
      return null;
    }
    final file = _layout.fileFor(specName);
    if (file.isEmpty) return null;
    return '../models/$file';
  }

  void _addSchemaImports(
    SchemaObject schema,
    OperationItem op,
    Set<String> importSet,
  ) {
    if (schema is ArraySchema) {
      _addSingleSchemaImport(
        schema.items,
        op,
        isRequest: false,
        importSet: importSet,
      );
    } else {
      _addSingleSchemaImport(
        schema,
        op,
        isRequest: false,
        importSet: importSet,
      );
    }
  }

  void _addSingleSchemaImport(
    SchemaObject schema,
    OperationItem op, {
    required bool isRequest,
    required Set<String> importSet,
  }) {
    if (schema is ArraySchema) {
      // Recurse into array items
      _addSingleSchemaImport(
        schema.items,
        op,
        isRequest: isRequest,
        importSet: importSet,
      );
      return;
    }

    final String specName;
    if (schema.name != null) {
      specName = schema.name!;
    } else {
      // Inline schema: look up computed name
      final base = _methodBaseName(op);
      specName = isRequest ? '${base}Request' : '${base}Response';
    }

    final import = _modelImport(specName);
    if (import != null) importSet.add(import);
  }

  List<String> _collectImports(
    List<OperationItem> ops,
    Map<OperationItem, _BodyPlan> bodyPlans,
  ) {
    final importSet = _collectModelImports(ops, bodyPlans);
    return importSet.toList()..sort();
  }

  // ---------------------------------------------------------------------------
  // Method builder
  // ---------------------------------------------------------------------------

  Method _buildMethod(
    OperationItem op,
    _BodyPlan body,
    List<String> non200Primary,
    List<String> untypedPrimary,
  ) {
    final pathParams =
        op.parameters.where((p) => p.location == 'path').toList();
    final queryParams =
        op.parameters
            .where((p) => p.location == 'query' || p.location == 'querystring')
            .toList();
    final headerParams =
        op.parameters.where((p) => p.location == 'header').toList();
    final cookieParams =
        op.parameters.where((p) => p.location == 'cookie').toList();

    if (cookieParams.isNotEmpty) {
      onWarning?.call(
        'Operation "${op.operationId ?? "${op.method} ${op.path}"}" has '
        '"in: cookie" parameters which are not supported in generated code. '
        'Use Dio interceptors for cookie-based auth.',
      );
    }

    for (final warning in body.warnings) {
      onWarning?.call('Operation "${_opLabel(op)}": $warning');
    }

    final returnType = _resolveReturnType(op, non200Primary, untypedPrimary);
    final responseKind = _responseKind(op);
    final methodName = _methodName(op);
    final orderedPathParams = _extractPathParamOrder(op.path, pathParams);
    final hasBody = body.type != null;
    final bodyRequired = body.required;
    final bodyType = body.type;
    final verbLower = op.method.toLowerCase();
    final emitSendProgress =
        verbLower != 'get' &&
        verbLower != 'head' &&
        verbLower != 'delete' &&
        verbLower != 'options';
    final emitReceiveProgress = verbLower != 'head' && verbLower != 'delete';

    return Method((m) {
      // Dartdoc
      final docTitle =
          op.summary ??
          op.operationId ??
          '${op.method.toUpperCase()} ${op.path}';
      m.docs.add('/// $docTitle');
      if (op.description != null && op.description != op.summary) {
        m.docs.add('///');
        for (final line in op.description!.split('\n')) {
          m.docs.add('/// $line');
        }
      }
      final paramsWithDesc =
          [...pathParams, ...queryParams, ...headerParams]
              .where((p) => p.description != null && p.description!.isNotEmpty)
              .toList();
      if (paramsWithDesc.isNotEmpty) {
        m.docs.add('///');
        m.docs.add('/// Parameters:');
        for (final p in paramsWithDesc) {
          final dartParamName = escapeKeyword(toLowerCamelCase(p.name));
          m.docs.add('/// - [$dartParamName] ${p.description}');
        }
      }
      final responseDoc = switch (responseKind) {
        _ResponseKind.text =>
          'Returns the `${_selectPrimary2xx(op.responses)!.mediaType}` '
              'response body as text.',
        _ResponseKind.bytes =>
          'Returns the `${_selectPrimary2xx(op.responses)!.mediaType}` '
              'response body as raw bytes.',
        _ => null,
      };
      for (final paragraph in [
        ...body.docs,
        if (responseDoc != null) responseDoc,
      ]) {
        m.docs.add('///');
        for (final line in _wrapDoc(paragraph)) {
          m.docs.add('/// $line');
        }
      }
      m.docs.add('///');
      m.docs.add('/// Throws [DioException] on non-2xx response.');

      m.name = methodName;
      m.returns = refer(returnType);
      m.modifier = MethodModifier.async;

      // Positional required params: path params first, then required body
      for (final p in orderedPathParams) {
        final dartName = escapeKeyword(toLowerCamelCase(p.name));
        final type = _schemaParamType(p.schema, required: true);
        m.requiredParameters.add(
          Parameter((param) {
            param.name = dartName;
            param.type = refer(type);
          }),
        );
      }
      if (hasBody && bodyRequired && bodyType != null) {
        m.requiredParameters.add(
          Parameter((param) {
            param.name = 'body';
            param.type = refer(bodyType);
          }),
        );
      }

      // Named params: required query params first, then optional query params
      for (final p in queryParams) {
        final dartName = escapeKeyword(toLowerCamelCase(p.name));
        final type = _schemaParamType(p.schema, required: p.required);
        m.optionalParameters.add(
          Parameter((param) {
            param.name = dartName;
            param.type = refer(type);
            param.named = true;
            param.required = p.required;
          }),
        );
      }
      // Header params
      for (final p in headerParams) {
        final dartName = escapeKeyword(toLowerCamelCase(p.name));
        m.optionalParameters.add(
          Parameter((param) {
            param.name = dartName;
            param.type = refer(p.required ? 'String' : 'String?');
            param.named = true;
            param.required = p.required;
          }),
        );
      }
      // Optional body
      if (hasBody && !bodyRequired && bodyType != null) {
        m.optionalParameters.add(
          Parameter((param) {
            param.name = 'body';
            param.type = refer('$bodyType?');
            param.named = true;
          }),
        );
      }
      // Content type of an untyped body
      if (body.contentTypeParam case final contentTypeParam?) {
        m.optionalParameters.add(
          Parameter((param) {
            param.name = contentTypeParam;
            param.type = refer('String');
            param.named = true;
            if (body.contentTypeDefault case final value?) {
              param.defaultTo = Code(dartStringLiteral(value));
            } else {
              param.required = true;
            }
          }),
        );
      }
      // Dio override params
      m.optionalParameters.add(
        Parameter((p) {
          p.name = 'cancelToken';
          p.type = refer('CancelToken?');
          p.named = true;
        }),
      );
      m.optionalParameters.add(
        Parameter((p) {
          p.name = 'headers';
          p.type = refer('Map<String, dynamic>?');
          p.named = true;
        }),
      );
      m.optionalParameters.add(
        Parameter((p) {
          p.name = 'extra';
          p.type = refer('Map<String, dynamic>?');
          p.named = true;
        }),
      );
      m.optionalParameters.add(
        Parameter((p) {
          p.name = 'validateStatus';
          p.type = refer('ValidateStatus?');
          p.named = true;
        }),
      );
      if (emitSendProgress) {
        m.optionalParameters.add(
          Parameter((p) {
            p.name = 'onSendProgress';
            p.type = refer('ProgressCallback?');
            p.named = true;
          }),
        );
      }
      if (emitReceiveProgress) {
        m.optionalParameters.add(
          Parameter((p) {
            p.name = 'onReceiveProgress';
            p.type = refer('ProgressCallback?');
            p.named = true;
          }),
        );
      }

      m.body = _buildMethodBody(
        op,
        pathParams: pathParams,
        queryParams: queryParams,
        headerParams: headerParams,
        returnType: returnType,
        responseKind: responseKind,
        body: body,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Additional method stubs (3.2)
  // ---------------------------------------------------------------------------

  List<Method> _buildAdditionalMethods(List<OperationItem> ops) {
    final methods = <Method>[];
    final emitted = <String>{};

    for (final op in ops) {
      for (final verb in op.additionalMethods) {
        final key = '${op.path}::$verb';
        if (!emitted.add(key)) continue;

        onWarning?.call(
          'Generated 3.2 non-standard verb stub: "$verb ${op.path}"',
        );

        final suffix = _pathToMethodSuffix(op.path);
        final methodName = escapeKeyword(toLowerCamelCase('$verb$suffix'));
        final pathExpr = _interpolatePath(
          op.path,
          op.parameters.where((p) => p.location == 'path').toList(),
        );

        methods.add(
          Method((m) {
            m.docs.add(
              '/// ${verb.toUpperCase()} ${op.path} (OpenAPI 3.2 additional operation)',
            );
            m.docs.add('///');
            m.docs.add('/// Throws [DioException] on non-2xx response.');
            m.name = methodName;
            m.returns = refer('Future<void>');
            m.modifier = MethodModifier.async;
            m.optionalParameters.addAll([
              Parameter((p) {
                p.name = 'cancelToken';
                p.type = refer('CancelToken?');
                p.named = true;
              }),
              Parameter((p) {
                p.name = 'headers';
                p.type = refer('Map<String, dynamic>?');
                p.named = true;
              }),
              Parameter((p) {
                p.name = 'extra';
                p.type = refer('Map<String, dynamic>?');
                p.named = true;
              }),
              Parameter((p) {
                p.name = 'validateStatus';
                p.type = refer('ValidateStatus?');
                p.named = true;
              }),
              Parameter((p) {
                p.name = 'onSendProgress';
                p.type = refer('ProgressCallback?');
                p.named = true;
              }),
              Parameter((p) {
                p.name = 'onReceiveProgress';
                p.type = refer('ProgressCallback?');
                p.named = true;
              }),
            ]);
            m.body = Block.of([
              refer('_dio')
                  .property('request')
                  .call(
                    [CodeExpression(Code(pathExpr))],
                    {
                      'options': refer('Options').call([], {
                        'method': literalString(verb.toUpperCase()),
                        'headers': refer('headers'),
                        'extra': refer('extra'),
                        'validateStatus': refer('validateStatus'),
                      }),
                      'cancelToken': refer('cancelToken'),
                      'onReceiveProgress': refer('onReceiveProgress'),
                    },
                    [refer('void')],
                  )
                  .awaited
                  .statement,
            ]);
          }),
        );
      }
    }

    return methods;
  }

  // ---------------------------------------------------------------------------
  // Method body builder
  // ---------------------------------------------------------------------------

  Block _buildMethodBody(
    OperationItem op, {
    required List<ParameterObject> pathParams,
    required List<ParameterObject> queryParams,
    required List<ParameterObject> headerParams,
    required String returnType,
    required _ResponseKind responseKind,
    required _BodyPlan body,
  }) {
    final method = op.method.toLowerCase();
    final isGetLike = _getLikeMethods.contains(method);
    final isDeleteLike = _deleteLikeMethods.contains(method);
    final bool isVoid = returnType == 'Future<void>';
    final bool isList = returnType.startsWith('Future<List<');
    final bool isMap = returnType == 'Future<Map<String, dynamic>>';
    // For a list response the union class is the *item* type, so
    // `Future<List<X>>` has to be unwrapped twice before asking the layout —
    // otherwise a list of a polymorphic union is decoded as if every element
    // were a JSON object.
    final innerType =
        isList
            ? RegExp(r'^Future<List<(.+)>>$').firstMatch(returnType)?.group(1)
            : RegExp(r'^Future<(.+)>$').firstMatch(returnType)?.group(1);
    final bool isPolymorphic =
        innerType != null && _layout.isPolymorphicUnion(innerType);

    return Block.of([
      ..._buildWarningComments(op),
      ..._buildHeaderStatements(headerParams),
      ..._buildQueryStatements(queryParams),
      for (final statement in body.statements) Code(statement),
      ..._buildDioCallStatements(
        op,
        pathParams: pathParams,
        queryParams: queryParams,
        headerParams: headerParams,
        method: method,
        isGetLike: isGetLike,
        isDeleteLike: isDeleteLike,
        isVoid: isVoid,
        isList: isList,
        isPolymorphic: isPolymorphic,
        responseKind: responseKind,
        body: body,
      ),
      ..._buildResponseStatements(
        returnType,
        isVoid: isVoid,
        isList: isList,
        isMap: isMap,
        isPolymorphic: isPolymorphic,
        isUndecoded:
            responseKind == _ResponseKind.text ||
            responseKind == _ResponseKind.bytes,
      ),
    ]);
  }

  List<Code> _buildWarningComments(OperationItem op) {
    final hasNon2xx = op.responses.keys.any(
      (k) => !k.startsWith('2') && k != 'default',
    );
    if (!hasNon2xx) return const [];
    return [
      Code(
        '// NOTE: only 2xx responses are handled. Add error handling for: '
        '${op.responses.keys.where((k) => !k.startsWith('2') && k != 'default').join(', ')}',
      ),
      Code('// Access error body via: (e as DioException).response?.data'),
    ];
  }

  List<Code> _buildHeaderStatements(List<ParameterObject> headerParams) {
    if (headerParams.isEmpty) return const [];
    final requiredH = headerParams.where((p) => p.required).toList();
    final optionalH = headerParams.where((p) => !p.required).toList();
    return [
      declareFinal('specHeaders')
          .assign(
            literalMap(
              {
                for (final p in requiredH)
                  p.name: refer(escapeKeyword(toLowerCamelCase(p.name))),
              },
              refer('String'),
              refer('dynamic'),
            ),
          )
          .statement,
      for (final p in optionalH)
        ifStatement(
          refer(
            escapeKeyword(toLowerCamelCase(p.name)),
          ).notEqualTo(literalNull),
          then: Block.of([
            refer('specHeaders')
                .index(literalString(p.name))
                .assign(refer(escapeKeyword(toLowerCamelCase(p.name))))
                .statement,
          ]),
        ),
      ifStatement(
        refer('headers').notEqualTo(literalNull),
        then: Block.of([
          refer(
            'specHeaders',
          ).property('addAll').call([refer('headers')]).statement,
        ]),
      ),
    ];
  }

  List<Code> _buildQueryStatements(List<ParameterObject> queryParams) {
    if (queryParams.isEmpty) return const [];
    final requiredQp = queryParams.where((p) => p.required).toList();
    final optionalQp = queryParams.where((p) => !p.required).toList();
    return [
      declareFinal('queryParameters')
          .assign(
            literalMap(
              {for (final p in requiredQp) p.name: _qpValueExpr(p)},
              refer('String'),
              refer('dynamic'),
            ),
          )
          .statement,
      for (final p in optionalQp)
        ifStatement(
          refer(
            escapeKeyword(toLowerCamelCase(p.name)),
          ).notEqualTo(literalNull),
          then: Block.of([
            refer(
              'queryParameters',
            ).index(literalString(p.name)).assign(_qpValueExpr(p)).statement,
          ]),
        ),
    ];
  }

  List<Code> _buildDioCallStatements(
    OperationItem op, {
    required List<ParameterObject> pathParams,
    required List<ParameterObject> queryParams,
    required List<ParameterObject> headerParams,
    required String method,
    required bool isGetLike,
    required bool isDeleteLike,
    required bool isVoid,
    required bool isList,
    required bool isPolymorphic,
    required _ResponseKind responseKind,
    required _BodyPlan body,
  }) {
    final hasBody = body.type != null;
    if (hasBody && isGetLike) {
      onWarning?.call(
        'Operation "${op.operationId ?? "${op.method} ${op.path}"}" is '
        '${op.method.toUpperCase()} but declares a requestBody. '
        'The body will not be sent (HTTP semantics). Use POST/PUT/PATCH instead.',
      );
    }

    final dioMethod = _dioMethodName(method);
    final needsMethodOption = !_namedDioMethods.contains(method);
    final supportsOnSendProgress = !isGetLike && !isDeleteLike;
    final supportsOnReceiveProgress = method != 'head' && !isDeleteLike;

    final dioTypeParam =
        isVoid
            ? 'void'
            : responseKind == _ResponseKind.text
            ? 'String'
            : responseKind == _ResponseKind.bytes
            ? 'Uint8List'
            // A list of a polymorphic union is still a JSON list at the top
            // level; only its elements are untyped.
            : isList
            ? 'List<dynamic>'
            // A polymorphic oneOf may arrive as an object or as a list, so the
            // response is not typed at the Dio level; the wrapper's fromJson
            // decides.
            : isPolymorphic
            ? 'dynamic'
            : 'Map<String, dynamic>';

    final namedArgs = <String, Expression>{};
    if (hasBody && !isGetLike && body.data != null) {
      namedArgs['data'] = body.data!;
    }
    if (queryParams.isNotEmpty) {
      namedArgs['queryParameters'] = refer('queryParameters');
    }
    namedArgs['options'] = _buildOptionsExpr(
      method,
      headerParams.isNotEmpty,
      needsMethodOption,
      contentType: isGetLike ? null : body.contentType,
      responseType: switch (responseKind) {
        _ResponseKind.text => refer('ResponseType').property('plain'),
        _ResponseKind.bytes => refer('ResponseType').property('bytes'),
        _ => null,
      },
    );
    namedArgs['cancelToken'] = refer('cancelToken');
    if (supportsOnSendProgress) {
      namedArgs['onSendProgress'] = refer('onSendProgress');
    }
    if (supportsOnReceiveProgress) {
      namedArgs['onReceiveProgress'] = refer('onReceiveProgress');
    }

    // pathExpr contains a Dart string interpolation literal — Code escape hatch
    final pathExpr = _interpolatePath(op.path, pathParams);
    final dioCall =
        refer('_dio')
            .property(dioMethod)
            .call(
              [CodeExpression(Code(pathExpr))],
              namedArgs,
              [refer(dioTypeParam)],
            )
            .awaited;

    return [
      isVoid
          ? dioCall.statement
          : declareFinal('response').assign(dioCall).statement,
    ];
  }

  List<Code> _buildResponseStatements(
    String returnType, {
    required bool isVoid,
    required bool isList,
    required bool isMap,
    required bool isPolymorphic,
    required bool isUndecoded,
  }) {
    if (isVoid) return const [];
    if (isUndecoded) {
      return [
        declareFinal(
          'data',
        ).assign(refer('response').property('data')).statement,
        ifStatement(
          refer('data').equalTo(literalNull),
          then: Block.of([
            refer('StateError')
                .call([
                  literalString('Expected a response body but received null.'),
                ])
                .thrown
                .statement,
          ]),
        ),
        refer('data').returned.statement,
      ];
    }

    String? innerType;
    if (isList) {
      innerType = RegExp(
        r'^Future<List<(.+)>>$',
      ).firstMatch(returnType)?.group(1);
    } else if (!isMap) {
      innerType = RegExp(r'^Future<(.+)>$').firstMatch(returnType)?.group(1);
    }

    final errorMsg =
        isList
            ? 'Expected JSON list response body but received null.'
            : isMap
            ? 'Expected JSON map response body but received null.'
            : 'Expected JSON response body but received null.';

    return [
      declareFinal('data').assign(refer('response').property('data')).statement,
      ifStatement(
        refer('data').equalTo(literalNull),
        then: Block.of([
          refer('StateError').call([literalString(errorMsg)]).thrown.statement,
        ]),
      ),
      if (isList && innerType != null)
        refer('data')
            .property('map')
            .call([
              Method((m) {
                m.lambda = true;
                m.requiredParameters.add(Parameter((p) => p.name = 'e'));
                m.body =
                    refer(innerType!).property('fromJson').call([
                      // A polymorphic union accepts Object?: an element may be
                      // an array or a primitive, so casting it to a JSON map
                      // would throw at runtime on exactly those branches.
                      isPolymorphic
                          ? refer('e')
                          : refer('e').asA(refer('Map<String, dynamic>')),
                    ]).code;
              }).closure,
            ])
            .property('toList')
            .call([])
            .returned
            .statement
      else if (isMap)
        refer(
          'Map<String, dynamic>',
        ).property('from').call([refer('data')]).returned.statement
      else if (innerType != null)
        refer(
          innerType,
        ).property('fromJson').call([refer('data')]).returned.statement,
    ];
  }

  // ---------------------------------------------------------------------------
  // Expression builders
  // ---------------------------------------------------------------------------

  Expression _buildOptionsExpr(
    String method,
    bool hasHeaderParams,
    bool needsMethodOption, {
    Expression? contentType,
    Expression? responseType,
  }) => refer('Options').call([], {
    if (needsMethodOption) 'method': literalString(method.toUpperCase()),
    if (contentType != null) 'contentType': contentType,
    if (responseType != null) 'responseType': responseType,
    'headers': hasHeaderParams ? refer('specHeaders') : refer('headers'),
    'extra': refer('extra'),
    'validateStatus': refer('validateStatus'),
  });

  Expression _buildBodyExpr(String bodyType, bool bodyRequired) {
    final needsToJson =
        bodyType != 'Map<String, dynamic>' && !bodyType.startsWith('List<');
    if (!needsToJson) return refer('body');
    return bodyRequired
        ? refer('body').property('toJson').call([])
        : refer('body').nullSafeProperty('toJson').call([]);
  }

  Expression _qpValueExpr(ParameterObject p) {
    final dart = escapeKeyword(toLowerCamelCase(p.name));
    // Dio stringifies query values with toString(), which for a DateTime emits
    // "2026-08-18 10:00:00.000" instead of an ISO-8601 instant.
    if (_paramIsDateTime(p.schema)) {
      return p.required
          ? refer(dart).property('toIso8601String').call([])
          : refer(dart).nullSafeProperty('toIso8601String').call([]);
    }
    final needsJson = _paramNeedsToJson(p.schema);
    if (!needsJson) return refer(dart);
    return p.required
        ? refer(dart).property('toJson').call([])
        : refer(dart).nullSafeProperty('toJson').call([]);
  }

  // ---------------------------------------------------------------------------
  // Return type resolution
  // ---------------------------------------------------------------------------

  // Sort remaining 2xx keys so selection is deterministic regardless of
  // insertion order in the parsed spec map.
  ResponseObject? _selectPrimary2xx(Map<String, ResponseObject> responses) =>
      responses['200'] ??
      responses['201'] ??
      (responses.entries.where((e) => e.key.startsWith('2')).toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
          .firstOrNull
          ?.value;

  /// Resolves the Dart return type of [op], recording into [non200Primary] the
  /// operations whose primary 2xx response is not `200`, and into
  /// [untypedPrimary] those whose primary response is not JSON.
  ///
  /// Picking e.g. `201` when it is the only declared success response is
  /// correct behaviour, so it is not worth a warning per operation; the caller
  /// emits a single aggregated line at the end of [generate]. The same goes
  /// for a download returned as bytes.
  String _resolveReturnType(
    OperationItem op,
    List<String> non200Primary,
    List<String> untypedPrimary,
  ) {
    final primary = _selectPrimary2xx(op.responses);
    if (primary == null) {
      onWarning?.call(
        'Operation "${op.operationId ?? "${op.method} ${op.path}"}" has no 2xx '
        'response — returning Future<void>.',
      );
      return 'Future<void>';
    }
    if (primary.statusCode != '200' && primary.statusCode.startsWith('2')) {
      non200Primary.add(
        '${op.operationId ?? "${op.method} ${op.path}"} (${primary.statusCode})',
      );
    }
    switch (_responseKind(op)) {
      case _ResponseKind.none:
        if (primary.kind != null) {
          onWarning?.call(
            'Operation "${_opLabel(op)}": the ${primary.statusCode} response is '
            '"${primary.mediaType}" without a schema — returning Future<void>.',
          );
        }
        return 'Future<void>';
      case _ResponseKind.text:
        untypedPrimary.add('${_opLabel(op)} (${primary.mediaType} → String)');
        return 'Future<String>';
      case _ResponseKind.bytes:
        untypedPrimary.add(
          '${_opLabel(op)} (${primary.mediaType} → Uint8List)',
        );
        return 'Future<Uint8List>';
      case _ResponseKind.json:
        return 'Future<${_schemaToType(primary.schema!, op)}>';
    }
  }

  /// How the generated method decodes the primary 2xx response of [op].
  _ResponseKind _responseKind(OperationItem op) {
    final primary = _selectPrimary2xx(op.responses);
    return switch (primary?.kind) {
      null => _ResponseKind.none,
      MediaTypeKind.json =>
        primary!.schema == null ? _ResponseKind.none : _ResponseKind.json,
      MediaTypeKind.text => _ResponseKind.text,
      _ => _ResponseKind.bytes,
    };
  }

  String _schemaToType(SchemaObject schema, OperationItem op) {
    if (schema is ArraySchema) {
      final itemType = _itemType(schema.items, op);
      return 'List<$itemType>';
    }
    // Named component schema
    if (schema.name != null) {
      try {
        return _registry.dartClassName(schema.name!);
      } on StateError {
        return 'Map<String, dynamic>';
      }
    }
    // Inline response schema: look up by computed name
    final base = _methodBaseName(op);
    final computedName = '${base}Response';
    try {
      return _registry.dartClassName(computedName);
    } on StateError {
      return 'Map<String, dynamic>';
    }
  }

  String _itemType(SchemaObject items, OperationItem op) {
    if (items.name != null) {
      try {
        return _registry.dartClassName(items.name!);
      } on StateError {
        return 'Map<String, dynamic>';
      }
    }
    return 'Map<String, dynamic>';
  }

  // ---------------------------------------------------------------------------
  // Request body plan
  // ---------------------------------------------------------------------------

  /// Decides how the method of [op] takes and sends its request body.
  ///
  /// The media type was chosen by the parser (see [selectMediaType]): a JSON
  /// body is typed and sent as JSON; a form body (url-encoded or multipart)
  /// is typed with its model and encoded field by field; anything else, and a
  /// form body whose schema is not an object, is taken untyped and sent as-is.
  _BodyPlan _planBody(OperationItem op) {
    final plan = _planBodyOf(op);
    // A GET-like method never sends its body (see _buildDioCallStatements),
    // so there is nothing to encode.
    return _getLikeMethods.contains(op.method.toLowerCase())
        ? plan.withoutEncoding()
        : plan;
  }

  _BodyPlan _planBodyOf(OperationItem op) {
    final requestBody = op.requestBody;
    final kind = requestBody?.kind;
    if (requestBody == null || kind == null) return const _BodyPlan();
    final mediaType = requestBody.mediaType ?? 'application/json';
    final required = requestBody.required;
    final schema = requestBody.schema;

    switch (kind) {
      case MediaTypeKind.json:
        if (schema == null) {
          return _BodyPlan(
            warnings: [
              'the "$mediaType" request body declares no schema; the method '
                  'takes no body.',
            ],
          );
        }
        final type = _resolveBodyType(op);
        return _BodyPlan(
          type: type,
          required: required,
          isTyped: true,
          data: _buildBodyExpr(type, required),
          // Dio sends a map as `application/json` by default; any other JSON
          // media type has to be set explicitly.
          contentType:
              mediaType == 'application/json'
                  ? null
                  : CodeExpression(Code(dartStringLiteral(mediaType))),
        );
      case MediaTypeKind.formUrlEncoded:
      case MediaTypeKind.multipart:
        return _planFormBody(op, requestBody);
      case MediaTypeKind.text:
      case MediaTypeKind.other:
        return _planUntypedBody(
          op,
          requestBody,
          'the request body media type "$mediaType" is not typed',
        );
    }
  }

  _BodyPlan _planFormBody(OperationItem op, RequestBodyObject requestBody) {
    final mediaType = requestBody.mediaType!;
    final isMultipart = requestBody.kind == MediaTypeKind.multipart;
    final required = requestBody.required;
    final schema = requestBody.schema;
    if (schema == null) {
      return _planUntypedBody(
        op,
        requestBody,
        'the "$mediaType" request body declares no schema',
      );
    }

    final type = _resolveBodyType(op);
    final warnings = <String>[];
    final docs = [
      isMultipart
          ? '[body] is sent as `multipart/form-data`, encoded into a new '
              '[FormData] on every call. A [FormData] can be sent only once: '
              'an interceptor that sends this request again (a token refresh, '
              'a retry) has to send a copy, '
              '`(options.data as FormData).clone()`, instead of the same '
              'instance.'
          : '[body] is sent as `application/x-www-form-urlencoded`.',
    ];
    _BodyPlan plan({
      List<String> statements = const [],
      required Expression data,
      bool needsJsonEncode = false,
    }) => _BodyPlan(
      type: type,
      required: required,
      isTyped: true,
      statements: statements,
      data: data,
      // Dio derives the multipart Content-Type, boundary included, from the
      // FormData itself.
      contentType:
          isMultipart
              ? null
              : refer('Headers').property('formUrlEncodedContentType'),
      docs: docs,
      warnings: warnings,
      needsJsonEncode: needsJsonEncode,
    );

    // A free-form object: the map is handed to Dio as it is.
    if (type == 'Map<String, dynamic>') {
      return plan(data: _formMapExpr(null, isMultipart, required));
    }

    final modelName = requestBodySchemaName(op);
    final formSchema = _formSchema(schema);
    final properties =
        modelName == null
            ? null
            : formProperties(
              formSchema,
              modelName,
              _registry,
              requestBody.encoding,
            );
    if (properties == null) {
      return _planUntypedBody(
        op,
        requestBody,
        'the "$mediaType" request body schema is not an object',
      );
    }

    if (formSchema
        case ObjectSchema(
          :final additionalProperties,
          properties: final declared,
        )
        when additionalProperties != null &&
            additionalProperties != false &&
            declared.every((p) => p.specName != 'additionalProperties')) {
      // A model that is nothing but a map sends that map.
      if (properties.isEmpty) {
        return plan(
          data: _formMapExpr('additionalProperties', isMultipart, required),
        );
      }
      warnings.add(
        'the additional properties of the "$mediaType" request body are not '
        'sent, only its declared properties.',
      );
    }

    for (final p in properties) {
      final contentType = p.encoding?.contentType;
      if (contentType != null && isBinarySchema(p.schema)) {
        docs.add(
          'The spec expects the `${p.wireName}` file as `$contentType`: set '
          'it as the `contentType` of its [MultipartFile].',
        );
      }
    }

    final encoder = FormBodyEncoder(_dateTimeConverter, warnings.add);
    if (isMultipart) {
      final adds = encoder.multipartStatements(properties);
      return plan(
        statements: [
          'final formData = FormData();',
          if (required)
            ...adds
          else if (adds.isNotEmpty) ...[
            'if (body != null) {',
            ...adds,
            '}',
          ],
        ],
        data:
            required
                ? refer('formData')
                : CodeExpression(const Code('body == null ? null : formData')),
        needsJsonEncode: adds.any((line) => line.contains('jsonEncode(')),
      );
    }

    final toJson =
        required
            ? refer('body').property('toJson').call([])
            : refer('body').nullSafeProperty('toJson').call([]);
    final listFormats = encoder.urlEncodedListFormats(properties);
    if (listFormats.isEmpty) return plan(data: toJson);
    final adjustments = [
      for (final MapEntry(:key, :value) in listFormats.entries) ...[
        'if (formFields[${dartStringLiteral(key)}] '
            'case final List<dynamic> value) {',
        'formFields[${dartStringLiteral(key)}] = ListParam(value, $value);',
        '}',
      ],
    ];
    return plan(
      statements: [
        'final formFields = ${toJson.accept(DartEmitter())};',
        if (required)
          ...adjustments
        else ...[
          'if (formFields != null) {',
          ...adjustments,
          '}',
        ],
      ],
      data: refer('formFields'),
    );
  }

  /// The `data:` of a form body sent as a map: `body` itself, or its
  /// [member] when given.
  Expression _formMapExpr(String? member, bool isMultipart, bool required) {
    final map = member == null ? 'body' : 'body.$member';
    if (!isMultipart) {
      // An optional body is null: so is the map.
      return CodeExpression(
        Code(required || member == null ? map : 'body?.$member'),
      );
    }
    // `body` is promoted to non-null past the null check.
    return CodeExpression(
      Code(
        required
            ? 'FormData.fromMap($map)'
            : 'body == null ? null : FormData.fromMap($map)',
      ),
    );
  }

  /// A body the method takes as `Object` and sends as-is, with the media type
  /// declared by the spec as `Content-Type` — overridable through a
  /// `contentType` parameter. [reason] starts the build warning.
  _BodyPlan _planUntypedBody(
    OperationItem op,
    RequestBodyObject requestBody,
    String reason,
  ) {
    final mediaType = requestBody.mediaType!;
    // A media type range (`*/*`, `image/*`) is not a valid Content-Type: the
    // caller has to name one.
    final defaultContentType = mediaType.contains('*') ? null : mediaType;
    final paramNames = {
      for (final p in op.parameters) escapeKeyword(toLowerCamelCase(p.name)),
    };
    final contentTypeParam =
        paramNames.contains('contentType') ? 'bodyContentType' : 'contentType';
    return _BodyPlan(
      type: 'Object',
      required: requestBody.required,
      data: refer('body'),
      contentType: refer(contentTypeParam),
      contentTypeParam: contentTypeParam,
      contentTypeDefault: defaultContentType,
      docs: [
        '[body] is sent as it is, with the `Content-Type` [$contentTypeParam] '
            '(the spec declares `$mediaType`): pass a `String`, a `Uint8List` '
            'or a `Stream<List<int>>`.',
      ],
      warnings: [
        defaultContentType == null
            ? '$reason; the method takes it as `Object body`, sent as it is '
                'with a required `$contentTypeParam` (the spec only declares '
                'the range "$mediaType").'
            : '$reason; the method takes it as `Object body`, sent as it is '
                'with the Content-Type "$mediaType" (overridable through '
                '`$contentTypeParam`).',
      ],
    );
  }

  /// The object schema encoded field by field for a form body: an anonymous
  /// single-member `allOf` (`allOf: [$ref]`) stands for its member.
  SchemaObject _formSchema(SchemaObject schema) => switch (schema) {
    AllOfSchema() when schema.name == null && schema.schemas.length == 1 =>
      schema.schemas.first,
    _ => schema,
  };

  // ---------------------------------------------------------------------------
  // Request body type resolution
  // ---------------------------------------------------------------------------

  String _resolveBodyType(OperationItem op) {
    final schema = op.requestBody?.schema;
    if (schema == null) return 'Map<String, dynamic>';

    if (schema is ArraySchema) {
      final itemType = _itemType(schema.items, op);
      return 'List<$itemType>';
    }
    if (schema.name != null) {
      try {
        return _registry.dartClassName(schema.name!);
      } on StateError {
        return 'Map<String, dynamic>';
      }
    }
    // Inline request body schema
    final base = _methodBaseName(op);
    final computedName = '${base}Request';
    try {
      return _registry.dartClassName(computedName);
    } on StateError {
      return 'Map<String, dynamic>';
    }
  }

  // ---------------------------------------------------------------------------
  // Parameter type resolution
  // ---------------------------------------------------------------------------

  String _schemaParamType(SchemaObject schema, {required bool required}) {
    final baseType = _paramBaseType(schema);
    return required ? baseType : '$baseType?';
  }

  String _paramBaseType(SchemaObject schema) {
    // _CyclicRefSchema is private to schema_object.dart; use isCyclicRef() to
    // detect it before entering the switch. Cyclic refs used as parameter types
    // are resolved using the target type name and emitted as a late field.
    if (isCyclicRef(schema)) {
      final targetName = cyclicRefTargetName(schema);
      final targetClass = _registry.dartClassName(targetName);
      onWarning?.call(
        'Cyclic reference detected for type "$targetName" — emitting late field '
        'of type "$targetClass" for parameter.',
      );
      return targetClass;
    }
    return switch (schema) {
      // Mirrors ModelGenerator's primitive mapping: string + date-time is a
      // DateTime, not a String.
      PrimitiveSchema(primitiveType: 'string', format: 'date-time') =>
        'DateTime',
      PrimitiveSchema(primitiveType: 'string') => 'String',
      PrimitiveSchema(primitiveType: 'integer') => 'int',
      PrimitiveSchema(primitiveType: 'number') => 'double',
      PrimitiveSchema(primitiveType: 'boolean') => 'bool',
      ArraySchema() => 'List<dynamic>',
      ObjectSchema() when schema.name != null => _registry.dartClassName(
        schema.name!,
      ),
      EnumSchema() when schema.name != null => _registry.dartClassName(
        schema.name!,
      ),
      AllOfSchema() when schema.name != null => _registry.dartClassName(
        schema.name!,
      ),
      OneOfSchema() when schema.name != null => _registry.dartClassName(
        schema.name!,
      ),
      // Anonymous allOf (e.g. allOf: [$ref, {nullable: true}] in OpenAPI 3.0):
      // extract the type from the first meaningful schema in the list.
      AllOfSchema() when schema.schemas.isNotEmpty => _paramBaseType(
        schema.schemas.first,
      ),
      _ => 'Map<String, dynamic>',
    };
  }

  /// Returns true when a query/header param needs `.toJson()` to serialize correctly.
  ///
  /// Enums, objects, and named allOf/oneOf wrappers have a `.toJson()` method.
  /// Primitives and anonymous schemas do not.
  bool _paramNeedsToJson(SchemaObject schema) {
    final effective = _effectiveSchema(schema);
    return switch (effective) {
      EnumSchema() when effective.name != null => true,
      ObjectSchema() when effective.name != null => true,
      AllOfSchema() when effective.name != null => true,
      OneOfSchema() when effective.name != null => true,
      _ => false,
    };
  }

  // ---------------------------------------------------------------------------
  // Path interpolation
  // ---------------------------------------------------------------------------

  String _interpolatePath(String path, List<ParameterObject> pathParams) {
    var result = path;
    for (final p in pathParams) {
      final dartName = escapeKeyword(toLowerCamelCase(p.name));
      // Uri.encodeComponent takes a String, so every parameter that is not one
      // has to be converted first — otherwise the generated service does not
      // compile (an `int` path parameter used to emit
      // `Uri.encodeComponent(id)`).
      //
      // Generated types serialize through toJson() to get their wire value;
      // .toString() then covers enums whose wire values are numbers.
      final String valueExpr;
      if (_paramNeedsToJson(p.schema)) {
        if (_pathParamIsObjectLike(p.schema)) {
          onWarning?.call(
            'Path parameter "${p.name}" is an object; serialized with '
            'toJson().toString(), which writes a Dart map literal into the '
            'URL. OpenAPI "style"/"explode" serialization of object path '
            'parameters is not supported.',
          );
        }
        valueExpr = '$dartName.toJson().toString()';
      } else if (_pathParamIsString(p.schema)) {
        valueExpr = dartName;
      } else if (_paramIsDateTime(p.schema)) {
        // Path params are always required, so no null-aware access is needed.
        valueExpr = _dateTimeToWire(dartName);
      } else {
        if (p.schema is ArraySchema) {
          onWarning?.call(
            'Path parameter "${p.name}" is an array; serialized with '
            'toString(). OpenAPI "style"/"explode" are not supported.',
          );
        }
        valueExpr = '$dartName.toString()';
      }
      result = result.replaceAll(
        '{${p.name}}',
        '\${Uri.encodeComponent($valueExpr)}',
      );
    }
    // Escape any single quotes present in the raw path so the emitted Dart
    // string literal remains syntactically valid.
    final escaped = result.replaceAll("'", r"\'");
    return "'$escaped'";
  }

  /// Unwraps an anonymous `allOf` wrapper (the OpenAPI 3.0 `nullable` pattern,
  /// `allOf: [$ref, {nullable: true}]`) to the schema that actually carries the
  /// type; any other schema is returned unchanged.
  SchemaObject _effectiveSchema(SchemaObject schema) => switch (schema) {
    AllOfSchema() when schema.name == null && schema.schemas.isNotEmpty =>
      schema.schemas.first,
    _ => schema,
  };

  /// Whether [schema] already produces a Dart `String`, i.e. needs no
  /// conversion before [Uri.encodeComponent].
  ///
  /// `format: date-time` is excluded on purpose: it maps to `DateTime`, not to
  /// `String` (see [_paramBaseType]), so it needs an explicit conversion.
  bool _pathParamIsString(SchemaObject schema) {
    final effective = _effectiveSchema(schema);
    return effective is PrimitiveSchema &&
        effective.primitiveType == 'string' &&
        effective.format != 'date-time';
  }

  /// Whether [schema] produces a Dart `DateTime` and therefore has to be
  /// serialized explicitly before being written to a URL or a query string.
  bool _paramIsDateTime(SchemaObject schema) {
    final effective = _effectiveSchema(schema);
    return effective is PrimitiveSchema &&
        effective.primitiveType == 'string' &&
        effective.format == 'date-time';
  }

  /// The expression serializing the `DateTime` held by [dartName].
  ///
  /// TODO: the configured `date_time_converter` is not honoured here. Unlike
  /// `ModelGenerator`, [ServiceGenerator] is not given the `DateTimeConverter`,
  /// so path and query parameters are always serialized as ISO-8601 (the
  /// default converter) even when models use the `timestamp` converter.
  String _dateTimeToWire(String dartName) => '$dartName.toIso8601String()';

  /// Whether [schema] is a named object-like schema (object, allOf or oneOf)
  /// as opposed to an enum, which serializes to a scalar wire value.
  bool _pathParamIsObjectLike(SchemaObject schema) {
    final effective = _effectiveSchema(schema);
    return effective is ObjectSchema ||
        effective is AllOfSchema ||
        effective is OneOfSchema;
  }

  String _pathToMethodSuffix(String path) {
    return path
        .split('/')
        .where((s) => s.isNotEmpty)
        .map((s) => s.replaceAll(RegExp(r'[{}]'), ''))
        .where((s) => s.isNotEmpty)
        .map(toPascalCase)
        .join();
  }

  List<ParameterObject> _extractPathParamOrder(
    String path,
    List<ParameterObject> pathParams,
  ) {
    // Extract param names in order they appear in the path template
    final paramNames =
        RegExp(
          r'\{([^}]+)\}',
        ).allMatches(path).map((m) => m.group(1)!).toList();

    final result = <ParameterObject>[];
    for (final name in paramNames) {
      final param = pathParams.where((p) => p.name == name).firstOrNull;
      if (param != null) result.add(param);
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Dio method selection
  // ---------------------------------------------------------------------------

  String _dioMethodName(String method) {
    return switch (method) {
      'get' => 'get',
      'post' => 'post',
      'put' => 'put',
      'patch' => 'patch',
      'delete' => 'delete',
      'head' => 'head',
      // 'options' intentionally falls through to 'request' — _dio.options is a
      // BaseOptions property, not a callable HTTP method. All OPTIONS requests
      // must use _dio.request(options: Options(method: 'OPTIONS', ...)).
      _ => 'request', // options, trace, and any other non-standard verbs
    };
  }

  // ---------------------------------------------------------------------------
  // Naming helpers
  // ---------------------------------------------------------------------------

  String _tagToClassName(String tag) => '${toPascalCase(tag)}Api';

  String _tagToFileName(String tag) => 'services/${tagToSnake(tag)}_api.dart';

  /// Derives the PascalCase base name for an operation.
  ///
  /// Mirrors [_operationBaseName] in name_registry.dart (NAME-04).
  String _methodBaseName(OperationItem op) {
    if (op.operationId != null && op.operationId!.isNotEmpty) {
      return toPascalCase(op.operationId!);
    }
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

  /// Returns the lowerCamelCase, keyword-escaped Dart method name for [op].
  String _methodName(OperationItem op) =>
      escapeKeyword(toLowerCamelCase(_methodBaseName(op)));

  /// How build warnings name [op].
  String _opLabel(OperationItem op) =>
      op.operationId ?? '${op.method} ${op.path}';

  /// Splits [paragraph] into dartdoc lines that fit in 80 columns once
  /// indented and prefixed with `/// ` (6 characters).
  List<String> _wrapDoc(String paragraph) {
    final lines = <String>[];
    var line = '';
    for (final word in paragraph.split(' ')) {
      if (line.isNotEmpty && line.length + 1 + word.length > 74) {
        lines.add(line);
        line = word;
      } else {
        line = line.isEmpty ? word : '$line $word';
      }
    }
    if (line.isNotEmpty) lines.add(line);
    return lines;
  }

  // [toSnakeCase] and [tagToSnake] are shared utilities from name_converter.dart.
}

/// How a generated method decodes its primary 2xx response.
enum _ResponseKind {
  /// No body (`Future<void>`).
  none,

  /// A JSON body, decoded into its Dart type.
  json,

  /// A `text/*` or XML body, returned as a `String`.
  text,

  /// Any other body, returned as a `Uint8List`.
  bytes,
}

/// How a generated method takes and sends the request body of one operation.
final class _BodyPlan {
  /// The type of the `body` parameter, without `?`; null when the method
  /// takes no body.
  final String? type;

  /// Whether `body` is a required positional parameter (otherwise it is a
  /// named, nullable one).
  final bool required;

  /// Whether [type] comes from the body schema, whose model is then imported.
  final bool isTyped;

  /// Statements emitted before the Dio call (the encoding of a form body).
  final List<String> statements;

  /// The `data:` argument of the Dio call.
  final Expression? data;

  /// The `contentType:` of the call's `Options`; null leaves it to Dio.
  final Expression? contentType;

  /// Name of the `String` parameter carrying the Content-Type of an untyped
  /// body, and its default value (null makes it required).
  final String? contentTypeParam;
  final String? contentTypeDefault;

  /// Dartdoc paragraphs describing how the body is sent.
  final List<String> docs;

  /// Build warnings, completed with the operation name by the caller.
  final List<String> warnings;

  /// Whether [statements] use `jsonEncode` (`dart:convert`).
  final bool needsJsonEncode;

  /// This plan without the statements encoding the body, nor the docs
  /// describing how it is sent.
  _BodyPlan withoutEncoding() => _BodyPlan(
    type: type,
    required: required,
    isTyped: isTyped,
    data: data,
    contentType: contentType,
    contentTypeParam: contentTypeParam,
    contentTypeDefault: contentTypeDefault,
    warnings: warnings,
  );

  const _BodyPlan({
    this.type,
    this.required = false,
    this.isTyped = false,
    this.statements = const [],
    this.data,
    this.contentType,
    this.contentTypeParam,
    this.contentTypeDefault,
    this.docs = const [],
    this.warnings = const [],
    this.needsJsonEncode = false,
  });
}
