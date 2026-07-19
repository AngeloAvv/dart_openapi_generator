import 'package:code_builder/code_builder.dart';

import '../generator_config.dart';
import '../model/spec_document.dart';
import '../name_registry/keyword_escaper.dart';
import '../name_registry/name_converter.dart';
import 'code_builder_emitter.dart';

/// Generates the [ApiClient] aggregator class from a [SpecDocument].
///
/// Returns exactly one entry: `'api_client.dart'`.
/// The barrel file (named after `outputDir`'s last path segment) is emitted
/// by [FileWriter] after it has the complete merged file map.
///
/// Usage:
/// ```dart
/// final generator = AggregatorGenerator();
/// final files = generator.generate(doc, config);
/// ```
final class AggregatorGenerator {
  /// Optional warning sink. Reserved for future use.
  final void Function(String)? onWarning;

  const AggregatorGenerator({this.onWarning});

  /// Returns `{'api_client.dart': source}`.
  Map<String, String> generate(SpecDocument doc, GeneratorConfig config) {
    final tags = _collectSortedTags(doc);
    return {'api_client.dart': emitLibrary(_buildLibrary(doc, tags, config))};
  }

  // ---------------------------------------------------------------------------
  // Tag collection
  // ---------------------------------------------------------------------------

  List<String> _collectSortedTags(SpecDocument doc) {
    final tagSet = <String>{};
    for (final op in doc.operations) {
      tagSet.add(op.tags.isEmpty ? 'Default' : op.tags[0]);
    }
    return tagSet.toList()..sort();
  }

  // ---------------------------------------------------------------------------
  // Library builder
  // ---------------------------------------------------------------------------

  Library _buildLibrary(
    SpecDocument doc,
    List<String> sortedTags,
    GeneratorConfig config,
  ) {
    final needsConvert = _needsBasicAuth(doc);
    return Library((lib) {
      if (needsConvert) lib.directives.add(Directive.import('dart:convert'));
      lib.directives.add(Directive.import('package:dio/dio.dart'));
      for (final tag in sortedTags) {
        lib.directives.add(
          Directive.import('services/${tagToSnake(tag)}_api.dart'),
        );
      }
      lib.body.add(_buildClass(doc, sortedTags, config));
    });
  }

  // ---------------------------------------------------------------------------
  // Class builder
  // ---------------------------------------------------------------------------

  Class _buildClass(
    SpecDocument doc,
    List<String> sortedTags,
    GeneratorConfig config,
  ) {
    final escaped = escapeKeyword(config.clientName);
    if (escaped != config.clientName) {
      onWarning?.call(
        'Client name "${config.clientName}" is a Dart keyword; '
        'escaped to "$escaped"',
      );
    }
    return Class((c) {
      c.docs.add('/// Generated API client for ${config.clientName}.');
      c.name = escaped;
      c.fields.add(_buildDioField());
      c.fields.add(_buildBaseUrlField(doc));
      for (final tag in sortedTags) {
        c.fields.add(_buildServiceField(tag));
      }
      c.constructors.add(_buildMainConstructor());
      c.methods.addAll(_buildAuthMethods(doc));
    });
  }

  // ---------------------------------------------------------------------------
  // Field builders
  // ---------------------------------------------------------------------------

  Field _buildDioField() => Field((f) {
    f.name = '_dio';
    f.type = refer('Dio');
    f.late = true;
  });

  Field _buildBaseUrlField(SpecDocument doc) => Field((f) {
    f.name = '_defaultBaseUrl';
    f.type = refer('String');
    f.static = true;
    f.modifier = FieldModifier.constant;
    f.assignment = literalString(doc.baseUrl).code;
  });

  Field _buildServiceField(String tag) {
    final className = '${toPascalCase(tag)}Api';
    final fieldName = escapeKeyword(toLowerCamelCase(tag));
    return Field((f) {
      f.name = fieldName;
      f.type = refer(className);
      f.late = true;
      f.modifier = FieldModifier.final$;
      f.assignment = refer(className).call([refer('_dio')]).code;
    });
  }

  // ---------------------------------------------------------------------------
  // Constructor builder
  // ---------------------------------------------------------------------------

  Constructor _buildMainConstructor() {
    return Constructor((c) {
      c.optionalParameters.addAll([
        Parameter((p) {
          p.name = 'dio';
          p.type = refer('Dio?');
          p.named = true;
        }),
        Parameter((p) {
          p.name = 'baseUrl';
          p.type = refer('String?');
          p.named = true;
        }),
        Parameter((p) {
          p.name = 'interceptors';
          p.type = refer('List<Interceptor>?');
          p.named = true;
        }),
        Parameter((p) {
          p.name = 'connectTimeout';
          p.type = refer('Duration');
          p.named = true;
          p.defaultTo = Code('const Duration(seconds: 30)');
        }),
        Parameter((p) {
          p.name = 'receiveTimeout';
          p.type = refer('Duration');
          p.named = true;
          p.defaultTo = Code('const Duration(seconds: 30)');
        }),
      ]);
      c.body = Code('''
_dio = dio ??
    Dio(BaseOptions(
      baseUrl: baseUrl ?? _defaultBaseUrl,
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
    ));
if (interceptors != null) {
  _dio.interceptors.addAll(interceptors);
}''');
    });
  }

  // ---------------------------------------------------------------------------
  // Auth method builders
  // ---------------------------------------------------------------------------

  bool _needsBasicAuth(SpecDocument doc) {
    return doc.securitySchemes.values.any(
      (s) => s.type == 'http' && s.scheme?.toLowerCase() == 'basic',
    );
  }

  List<Method> _buildAuthMethods(SpecDocument doc) {
    if (doc.securitySchemes.isEmpty) return [];
    final methods = <Method>[];
    final emitted = <String>{};
    for (final scheme in doc.securitySchemes.values) {
      if (scheme.type == 'http' && scheme.scheme?.toLowerCase() == 'bearer') {
        if (emitted.add('bearer')) methods.add(_buildBearerMethod());
      } else if (scheme.type == 'http' &&
          scheme.scheme?.toLowerCase() == 'basic') {
        if (emitted.add('basic')) methods.add(_buildBasicAuthMethod());
      } else if (scheme.type == 'apiKey' && scheme.location == 'header') {
        if (emitted.add('apiKeyHeader')) {
          methods.add(
            _buildApiKeyHeaderMethod(scheme.paramName ?? 'X-Api-Key'),
          );
        }
      } else if (scheme.type == 'apiKey' && scheme.location == 'query') {
        if (emitted.add('apiKeyQuery')) {
          methods.add(_buildApiKeyQueryMethod(scheme.paramName ?? 'api_key'));
        }
      } else {
        onWarning?.call(
          'Unknown or unsupported auth scheme type "${scheme.type}" '
          '(scheme: "${scheme.scheme}", location: "${scheme.location}") — '
          'no auth helper generated for "${scheme.name}"',
        );
      }
    }
    return methods;
  }

  Method _buildBearerMethod() => Method((m) {
    m.docs.add(
      '/// Returns an [Interceptor] that adds a Bearer token to every request.',
    );
    m.static = true;
    m.lambda = true;
    m.name = 'bearerAuth';
    m.returns = refer('Interceptor');
    m.requiredParameters.add(
      Parameter((p) {
        p.name = 'token';
        p.type = refer('String');
      }),
    );
    m.body = Code(r"""InterceptorsWrapper(
    onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
      options.headers['Authorization'] = 'Bearer $token';
      handler.next(options);
    },
  )""");
  });

  Method _buildApiKeyHeaderMethod(String defaultHeaderName) => Method((m) {
    m.docs.add(
      '/// Returns an [Interceptor] that adds an API key header to every request.',
    );
    m.static = true;
    m.lambda = true;
    m.name = 'apiKeyAuth';
    m.returns = refer('Interceptor');
    m.requiredParameters.add(
      Parameter((p) {
        p.name = 'apiKey';
        p.type = refer('String');
      }),
    );
    m.optionalParameters.add(
      Parameter((p) {
        p.name = 'headerName';
        p.type = refer('String');
        p.named = true;
        p.defaultTo = Code("'$defaultHeaderName'");
      }),
    );
    m.body = Code(r"""InterceptorsWrapper(
    onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
      options.headers[headerName] = apiKey;
      handler.next(options);
    },
  )""");
  });

  Method _buildApiKeyQueryMethod(String defaultParamName) => Method((m) {
    m.docs.add(
      '/// Returns an [Interceptor] that adds an API key query parameter to every request.',
    );
    m.static = true;
    m.lambda = true;
    m.name = 'apiKeyQueryAuth';
    m.returns = refer('Interceptor');
    m.requiredParameters.add(
      Parameter((p) {
        p.name = 'apiKey';
        p.type = refer('String');
      }),
    );
    m.optionalParameters.add(
      Parameter((p) {
        p.name = 'paramName';
        p.type = refer('String');
        p.named = true;
        p.defaultTo = Code("'$defaultParamName'");
      }),
    );
    m.body = Code(r"""InterceptorsWrapper(
    onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
      options.queryParameters[paramName] = apiKey;
      handler.next(options);
    },
  )""");
  });

  Method _buildBasicAuthMethod() => Method((m) {
    m.docs.add(
      '/// Returns an [Interceptor] that adds HTTP Basic auth to every request.',
    );
    m.static = true;
    m.lambda = true;
    m.name = 'basicAuth';
    m.returns = refer('Interceptor');
    m.requiredParameters.addAll([
      Parameter((p) {
        p.name = 'username';
        p.type = refer('String');
      }),
      Parameter((p) {
        p.name = 'password';
        p.type = refer('String');
      }),
    ]);
    m.body = Code(r"""InterceptorsWrapper(
    onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
      final credentials = base64.encode(utf8.encode('$username:$password'));
      options.headers['Authorization'] = 'Basic $credentials';
      handler.next(options);
    },
  )""");
  });
}
