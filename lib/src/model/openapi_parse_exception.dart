import 'package:source_span/source_span.dart';

/// Thrown when the OpenAPI spec content fails validation.
///
/// Distinct from [InvalidGenerationSource] (which is for build-wiring errors).
/// [OpenApiBuilder] catches this and rethrows as [InvalidGenerationSource].
///
/// [message] describes what went wrong.
/// [jsonPointer] is the RFC 6901 JSON pointer to the offending node
///   (e.g. `#/components/schemas/User`).
/// [sourceSpan] is the YAML source location; `null` for JSON input
///   where spans are unavailable.
final class OpenApiParseException implements Exception {
  final String message;
  final String jsonPointer;
  final SourceSpan? sourceSpan;

  const OpenApiParseException(
    this.message, {
    required this.jsonPointer,
    this.sourceSpan,
  });

  @override
  String toString() {
    final location =
        sourceSpan != null
            ? ' (line ${sourceSpan!.start.line + 1}, '
                'col ${sourceSpan!.start.column + 1})'
            : '';
    return 'OpenAPI parse error at $jsonPointer$location: $message';
  }
}
