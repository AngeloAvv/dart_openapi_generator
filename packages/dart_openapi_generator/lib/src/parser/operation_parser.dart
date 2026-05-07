import '../model/openapi_parse_exception.dart';
import '../model/schema_object.dart';
import '../model/spec_document.dart';
import 'schema_parser.dart';
import 'source_map.dart';

/// Standard HTTP methods defined in OpenAPI 3.0/3.1/3.2 PathItem.
const _kStandardMethods = {
  'get',
  'post',
  'put',
  'patch',
  'delete',
  'head',
  'options',
  'trace',
};

/// PathItem metadata keys that are not operations.
const _kPathItemMetadataKeys = {
  'summary',
  'description',
  'parameters',
  'servers',
  r'$ref',
  'get',
  'post',
  'put',
  'patch',
  'delete',
  'head',
  'options',
  'trace',
};

/// Parses the `paths` object from a raw spec map into a list of [OperationItem]s.
///
/// Handles:
///   - All standard HTTP methods (GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS/TRACE)
///   - OpenAPI 3.2 `additionalOperations` (PARSE-08): non-standard verb strings
///     stored in [OperationItem.additionalMethods]
///   - `in: querystring` parameter location (PARSE-08)
///   - Inline request body and response schemas (named via operationId or path)
///
/// One instance per parse invocation.
final class OperationParser {
  final SourceMap _sourceMap;
  final SchemaParser _schemaParser;

  const OperationParser(this._sourceMap, this._schemaParser);

  /// Parses [paths] map (raw `paths:` object) into [OperationItem] list.
  ///
  /// [specVersion] controls version-specific behaviour (e.g., 3.2 features).
  List<OperationItem> parseOperations(
    Map<String, dynamic> paths,
    String specVersion,
  ) {
    final operations = <OperationItem>[];

    paths.forEach((pathKey, pathItemRaw) {
      if (pathItemRaw is! Map) return;
      final pathItem = Map<String, dynamic>.from(pathItemRaw);
      final pathPointer =
          '#/paths/${_encodePointerSegment(pathKey.toString())}';

      // Path-level parameters (merged into each operation, overridden by op-level)
      final pathLevelParams = _parseParameters(
        pathItem['parameters'] as List? ?? [],
        pathPointer,
      );

      // 3.2: additionalOperations (any string key not in the standard method set
      // and not a PathItem metadata key)
      final additionalMethods = <String>[];
      if (specVersion.startsWith('3.2')) {
        for (final key in pathItem.keys) {
          if (!_kPathItemMetadataKeys.contains(key)) {
            additionalMethods.add(key.toString());
          }
        }
      }

      // Parse each standard method present in this path item
      for (final method in _kStandardMethods) {
        final operationRaw = pathItem[method];
        if (operationRaw == null) continue;
        if (operationRaw is! Map) continue;

        final operation = Map<String, dynamic>.from(operationRaw);
        final opPointer = '$pathPointer/$method';

        operations.add(
          _parseOperation(
            operation,
            method,
            pathKey.toString(),
            opPointer,
            pathLevelParams,
            additionalMethods,
          ),
        );
      }
    });

    return operations;
  }

  OperationItem _parseOperation(
    Map<String, dynamic> op,
    String method,
    String path,
    String pointer,
    List<ParameterObject> pathLevelParams,
    List<String> additionalMethods,
  ) {
    final operationId = op['operationId'] as String?;
    final summary = op['summary'] as String?;
    final description = op['description'] as String?;
    final tags = (op['tags'] as List? ?? []).cast<String>();
    final security = _parseSecurity(op['security'] as List?);

    // Operation-level params override path-level params with same name+location
    final opParams = _parseParameters(op['parameters'] as List? ?? [], pointer);
    final mergedParams = _mergeParameters(pathLevelParams, opParams);

    // Request body
    RequestBodyObject? requestBody;
    final requestBodyRaw = op['requestBody'];
    if (requestBodyRaw is Map) {
      requestBody = _parseRequestBody(
        Map<String, dynamic>.from(requestBodyRaw),
        '$pointer/requestBody',
      );
    }

    // Responses
    final responsesRaw = op['responses'] as Map? ?? {};
    final responses = <String, ResponseObject>{};
    responsesRaw.forEach((statusCode, responseRaw) {
      if (responseRaw is! Map) return;
      final responsePointer = '$pointer/responses/$statusCode';
      responses[statusCode.toString()] = _parseResponse(
        Map<String, dynamic>.from(responseRaw),
        statusCode.toString(),
        responsePointer,
      );
    });

    return OperationItem(
      path: path,
      method: method,
      operationId: operationId,
      summary: summary,
      description: description,
      tags: tags,
      parameters: mergedParams,
      requestBody: requestBody,
      responses: responses,
      security: security,
      additionalMethods: additionalMethods,
    );
  }

  List<ParameterObject> _parseParameters(
    List<dynamic> rawList,
    String pointer,
  ) {
    final params = <ParameterObject>[];
    for (var i = 0; i < rawList.length; i++) {
      final raw = rawList[i];
      if (raw is! Map) continue;
      final paramMap = Map<String, dynamic>.from(raw);
      final paramPointer = '$pointer/parameters/$i';

      final name = paramMap['name'] as String?;
      if (name == null) {
        throw OpenApiParseException(
          'Parameter at index $i is missing required "name" field.',
          jsonPointer: paramPointer,
          sourceSpan: _sourceMap.spanAt(paramPointer),
        );
      }

      // 'in' field — supports 'querystring' for OpenAPI 3.2 (PARSE-08)
      final location = paramMap['in'] as String?;
      if (location == null) {
        throw OpenApiParseException(
          'Parameter "$name" is missing required "in" field.',
          jsonPointer: '$paramPointer/in',
          sourceSpan: _sourceMap.spanAt('$paramPointer/in'),
        );
      }

      final required = paramMap['required'] as bool? ?? (location == 'path');
      final description = paramMap['description'] as String?;
      final style = paramMap['style'] as String?;
      final explode = paramMap['explode'] as bool?;

      // Schema (required for parameters)
      SchemaObject schema;
      final schemaRaw = paramMap['schema'];
      if (schemaRaw is Map) {
        schema = _schemaParser.parse(
          Map<String, dynamic>.from(schemaRaw),
          '$paramPointer/schema',
        );
      } else {
        // Default to string schema if no schema specified
        schema = const PrimitiveSchema(primitiveType: 'string');
      }

      params.add(
        ParameterObject(
          name: name,
          location: location,
          description: description,
          required: required,
          schema: schema,
          style: style,
          explode: explode,
        ),
      );
    }
    return params;
  }

  /// Merges path-level and operation-level parameters.
  /// Operation-level params with the same name+location override path-level ones.
  List<ParameterObject> _mergeParameters(
    List<ParameterObject> pathLevel,
    List<ParameterObject> opLevel,
  ) {
    final merged = <String, ParameterObject>{};
    for (final p in pathLevel) {
      merged['${p.name}:${p.location}'] = p;
    }
    for (final p in opLevel) {
      merged['${p.name}:${p.location}'] = p; // overrides
    }
    return merged.values.toList();
  }

  RequestBodyObject _parseRequestBody(
    Map<String, dynamic> raw,
    String pointer,
  ) {
    final required = raw['required'] as bool? ?? false;
    final description = raw['description'] as String?;
    final content = raw['content'] as Map?;

    SchemaObject? jsonSchema;
    if (content != null) {
      final jsonContent = content['application/json'] as Map?;
      final schemaRaw = jsonContent?['schema'];
      if (schemaRaw is Map) {
        jsonSchema = _schemaParser.parse(
          Map<String, dynamic>.from(schemaRaw),
          '$pointer/content/application~1json/schema',
        );
      }
    }

    return RequestBodyObject(
      description: description,
      required: required,
      jsonSchema: jsonSchema,
    );
  }

  ResponseObject _parseResponse(
    Map<String, dynamic> raw,
    String statusCode,
    String pointer,
  ) {
    final description = raw['description'] as String?;
    final content = raw['content'] as Map?;

    SchemaObject? jsonSchema;
    if (content != null) {
      final jsonContent = content['application/json'] as Map?;
      final schemaRaw = jsonContent?['schema'];
      if (schemaRaw is Map) {
        jsonSchema = _schemaParser.parse(
          Map<String, dynamic>.from(schemaRaw),
          '$pointer/content/application~1json/schema',
        );
      }
    }

    return ResponseObject(
      statusCode: statusCode,
      description: description,
      jsonSchema: jsonSchema,
    );
  }

  List<String> _parseSecurity(List? securityList) {
    if (securityList == null) return const [];
    final names = <String>[];
    for (final item in securityList) {
      if (item is Map) {
        names.addAll(item.keys.cast<String>());
      }
    }
    return names;
  }

  /// Encodes a path segment for use in a JSON Pointer per RFC 6901.
  String _encodePointerSegment(String segment) =>
      segment.replaceAll('~', '~0').replaceAll('/', '~1');
}
