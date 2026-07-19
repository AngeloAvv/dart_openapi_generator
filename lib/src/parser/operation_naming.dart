import '../name_registry/name_converter.dart';

/// Derives the base name for an operation's inline request/response schemas.
///
/// Uses `operationId` if present; otherwise builds from HTTP method + path segments.
/// Path segments have leading slashes removed and `{param}` braces removed.
///
/// Examples:
///   operationId = 'getUser'   → 'GetUser'
///   method = 'get', path = '/users/{id}' → 'GetUsersId'
///
/// Shared by [buildNameRegistry] (name_registry.dart) and [OpenApiParser]
/// (openapi_parser.dart) so both agree on exactly the same computed name for
/// a given operation's inline body schema.
String operationBaseName(String? operationId, String method, String path) {
  if (operationId != null && operationId.isNotEmpty) {
    return toPascalCase(operationId);
  }
  final methodPart = toPascalCase(method);
  final pathParts =
      path
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
String responseSuffix(String statusCode) {
  if (statusCode == '200' || statusCode == '201') return 'Response';
  if (statusCode == 'default') return 'DefaultResponse';
  return 'Status${statusCode}Response';
}
