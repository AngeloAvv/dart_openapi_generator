/// How a generated method encodes a request body, or decodes a response body,
/// given its media type.
enum MediaTypeKind {
  /// `application/json`, with or without parameters (`; charset=utf-8`), and
  /// every `*/*+json` structured syntax (`application/problem+json`,
  /// `application/vnd.api+json`, ...).
  json,

  /// `application/x-www-form-urlencoded`.
  formUrlEncoded,

  /// `multipart/form-data`.
  multipart,

  /// `text/*` and the XML family: decoded as a `String`.
  text,

  /// Anything else (`application/octet-stream`, `image/png`, `*/*`, ...).
  other,
}

/// Classifies [mediaType], a key of an OpenAPI `content` map.
///
/// Parameters (`; charset=utf-8`) and case are ignored.
MediaTypeKind classifyMediaType(String mediaType) {
  final essence = mediaTypeEssence(mediaType);
  if (essence == 'application/json' || essence.endsWith('+json')) {
    return MediaTypeKind.json;
  }
  if (essence == 'application/x-www-form-urlencoded') {
    return MediaTypeKind.formUrlEncoded;
  }
  if (essence == 'multipart/form-data') return MediaTypeKind.multipart;
  if (essence.startsWith('text/') ||
      essence == 'application/xml' ||
      essence.endsWith('+xml')) {
    return MediaTypeKind.text;
  }
  return MediaTypeKind.other;
}

/// [mediaType] without its parameters, trimmed and lowercased:
/// `Application/JSON; charset=utf-8` → `application/json`.
String mediaTypeEssence(String mediaType) =>
    mediaType.split(';').first.trim().toLowerCase();

/// Picks, among the media types of a `content` map, the one a generated
/// method works with.
///
/// The first JSON media type wins, then `application/x-www-form-urlencoded`,
/// then `multipart/form-data`. When none of those is declared, the first
/// media type in spec order is returned: the generated method then exchanges
/// the body untyped. Returns null for an empty map.
///
/// Request bodies and responses share the rule; a response never reaches the
/// form kinds in practice.
String? selectMediaType(Iterable<String> mediaTypes) {
  const preference = [
    MediaTypeKind.json,
    MediaTypeKind.formUrlEncoded,
    MediaTypeKind.multipart,
  ];
  for (final kind in preference) {
    for (final mediaType in mediaTypes) {
      if (classifyMediaType(mediaType) == kind) return mediaType;
    }
  }
  return mediaTypes.firstOrNull;
}
