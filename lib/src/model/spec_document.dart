import 'package:meta/meta.dart';

import 'media_type.dart';
import 'schema_object.dart';

/// The primary output of the OpenAPI parser.
///
/// Represents a fully-parsed, `$ref`-free, frozen OpenAPI document.
/// Consumed by [ModelGenerator], [ServiceGenerator], and [AggregatorGenerator].
///
/// [specVersion] is the raw `openapi:` string from the spec (e.g., `"3.0.3"`).
/// [title] is `info.title`.
/// [baseUrl] is `servers[0].url`; empty string when no servers block is present.
/// [schemas] maps component name → resolved [SchemaObject] (from `components/schemas`).
/// [operations] is all parsed path+method combinations.
/// [securitySchemes] maps scheme name → [SecurityScheme] (from `components/securitySchemes`).
@immutable
final class SpecDocument {
  final String specVersion;
  final String title;
  final String baseUrl;
  final Map<String, SchemaObject> schemas;
  final List<OperationItem> operations;
  final Map<String, SecurityScheme> securitySchemes;

  const SpecDocument({
    required this.specVersion,
    required this.title,
    required this.baseUrl,
    required this.schemas,
    required this.operations,
    required this.securitySchemes,
  });
}

/// One HTTP verb × path combination from the OpenAPI `paths` object.
///
/// [path] is the raw path template (e.g., `/users/{id}`).
/// [method] is the lowercase HTTP method (`get`, `post`, `put`, `patch`,
///   `delete`, `head`, `options`, `trace`) or any string from
///   `additionalOperations` (OpenAPI 3.2,).
/// [operationId] is the value of `operationId`; null when not specified.
/// [tags] is the list of tag strings on this operation.
/// [parameters] is the resolved parameter list (path + query + header + cookie).
/// [requestBody] is null for operations without a request body.
/// [responses] maps HTTP status code string (e.g., `"200"`, `"default"`) → [ResponseObject].
/// [security] is the list of security scheme names on this operation; empty means
///   the global security applies.
/// [additionalMethods] captures 3.2 `additionalOperations` extra verb strings for
///   this path item (stored as-is; empty for 3.0/3.1 specs).
@immutable
final class OperationItem {
  final String path;
  final String method;
  final String? operationId;
  final String? summary;
  final String? description;
  final List<String> tags;
  final List<ParameterObject> parameters;
  final RequestBodyObject? requestBody;
  final Map<String, ResponseObject> responses;
  final List<String> security;
  final List<String> additionalMethods;

  const OperationItem({
    required this.path,
    required this.method,
    this.operationId,
    this.summary,
    this.description,
    required this.tags,
    required this.parameters,
    this.requestBody,
    required this.responses,
    required this.security,
    required this.additionalMethods,
  });
}

/// An OpenAPI Parameter Object.
///
/// [location] is `'path'`, `'query'`, `'header'`, `'cookie'`, or `'querystring'`
///   (the last is 3.2-only,).
/// [style] and [explode] are serialization hints used by the service generator.
@immutable
final class ParameterObject {
  final String name;
  final String location;
  final String? description;
  final bool required;
  final SchemaObject schema;
  final String? style;
  final bool? explode;

  const ParameterObject({
    required this.name,
    required this.location,
    this.description,
    required this.required,
    required this.schema,
    this.style,
    this.explode,
  });
}

/// An OpenAPI Request Body Object.
///
/// [mediaType] is the `content` key the generated method sends, chosen by
/// [selectMediaType]: JSON first, then `application/x-www-form-urlencoded`,
/// then `multipart/form-data`, otherwise the first declared media type. Null
/// when `content` is empty — or when the object is built in code with a
/// [schema] only, which then stands for JSON.
/// [schema] is the schema of [mediaType]. It is only parsed for the kinds the
/// generator types (JSON and the two form kinds); null otherwise, and null
/// when the media type declares no schema or an empty one.
/// [encoding] is the Encoding Object map of [mediaType], keyed by property
/// name; only meaningful for the two form kinds.
@immutable
final class RequestBodyObject {
  final String? description;
  final bool required;
  final String? mediaType;
  final SchemaObject? schema;
  final Map<String, EncodingObject> encoding;

  const RequestBodyObject({
    this.description,
    required this.required,
    this.mediaType,
    this.schema,
    this.encoding = const {},
  });

  /// How [mediaType] is encoded; null when the body declares no content.
  MediaTypeKind? get kind => _kind(mediaType, schema);
}

/// An OpenAPI Encoding Object: how one property of a form body is serialized.
///
/// [contentType] is the media type of the part (`multipart/form-data`).
/// [style], [explode] and [allowReserved] are the serialization hints of an
/// `application/x-www-form-urlencoded` property.
/// [hasHeaders] records that per-part `headers` were declared; they are not
/// generated.
@immutable
final class EncodingObject {
  final String? contentType;
  final String? style;
  final bool? explode;
  final bool allowReserved;
  final bool hasHeaders;

  const EncodingObject({
    this.contentType,
    this.style,
    this.explode,
    this.allowReserved = false,
    this.hasHeaders = false,
  });
}

/// An OpenAPI Response Object for a single HTTP status code.
///
/// [statusCode] is the string key from the responses map (e.g., `"200"`,
///   `"204"`, `"default"`).
/// [mediaType] is the `content` key the generated method decodes, chosen by
///   [selectMediaType]; null for a response without content (a 204), or
///   when the object is built in code with a [schema] only, which then
///   stands for JSON.
/// [schema] is the schema of [mediaType] when it is a JSON media type; null
///   for other media types and for JSON without a schema.
@immutable
final class ResponseObject {
  final String statusCode;
  final String? description;
  final String? mediaType;
  final SchemaObject? schema;

  const ResponseObject({
    required this.statusCode,
    this.description,
    this.mediaType,
    this.schema,
  });

  /// How [mediaType] is decoded; null when the response has no content.
  MediaTypeKind? get kind => _kind(mediaType, schema);
}

/// An OpenAPI Security Scheme Object (from `components/securitySchemes`).
///
/// [type] is `'http'`, `'apiKey'`, `'oauth2'`, or `'openIdConnect'`.
/// [scheme] is the HTTP auth scheme (e.g., `'bearer'`, `'basic'`); only
///   present for `type: http`.
/// [location] is where the API key is sent (`'header'` or `'query'`);
///   only present for `type: apiKey`.
/// [paramName] is the header/query parameter name; only present for `type: apiKey`.
@immutable
final class SecurityScheme {
  final String name;
  final String type;
  final String? scheme;
  final String? bearerFormat;
  final String? location;
  final String? paramName;

  const SecurityScheme({
    required this.name,
    required this.type,
    this.scheme,
    this.bearerFormat,
    this.location,
    this.paramName,
  });
}

MediaTypeKind? _kind(String? mediaType, SchemaObject? schema) =>
    mediaType != null
        ? classifyMediaType(mediaType)
        : schema != null
        ? MediaTypeKind.json
        : null;
