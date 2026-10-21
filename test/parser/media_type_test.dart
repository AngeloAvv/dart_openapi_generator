import 'package:dart_openapi_generator/src/model/media_type.dart';
import 'package:test/test.dart';

void main() {
  group('classifyMediaType', () {
    for (final (mediaType, kind) in [
      ('application/json', MediaTypeKind.json),
      ('application/json; charset=utf-8', MediaTypeKind.json),
      ('Application/JSON', MediaTypeKind.json),
      ('application/problem+json', MediaTypeKind.json),
      ('application/vnd.api+json', MediaTypeKind.json),
      ('application/merge-patch+json; charset=utf-8', MediaTypeKind.json),
      ('application/x-www-form-urlencoded', MediaTypeKind.formUrlEncoded),
      (
        'application/x-www-form-urlencoded; charset=utf-8',
        MediaTypeKind.formUrlEncoded,
      ),
      ('multipart/form-data', MediaTypeKind.multipart),
      ('text/plain', MediaTypeKind.text),
      ('text/csv; charset=utf-8', MediaTypeKind.text),
      ('application/xml', MediaTypeKind.text),
      ('application/atom+xml', MediaTypeKind.text),
      ('application/octet-stream', MediaTypeKind.other),
      ('image/png', MediaTypeKind.other),
      ('image/*', MediaTypeKind.other),
      ('*/*', MediaTypeKind.other),
      ('multipart/mixed', MediaTypeKind.other),
      ('application/jsonl', MediaTypeKind.other),
    ]) {
      test('$mediaType → ${kind.name}', () {
        expect(classifyMediaType(mediaType), kind);
      });
    }
  });

  group('selectMediaType', () {
    test('returns null for an empty content map', () {
      expect(selectMediaType(const []), isNull);
    });

    test('JSON wins over every other kind, wherever it is declared', () {
      expect(
        selectMediaType(const [
          'multipart/form-data',
          'application/x-www-form-urlencoded',
          'application/xml',
          'application/json',
        ]),
        'application/json',
      );
    });

    test('a JSON variant counts as JSON', () {
      expect(
        selectMediaType(const [
          'application/x-www-form-urlencoded',
          'application/vnd.api+json',
        ]),
        'application/vnd.api+json',
      );
    });

    test('url-encoded wins over multipart', () {
      expect(
        selectMediaType(const [
          'multipart/form-data',
          'application/x-www-form-urlencoded',
        ]),
        'application/x-www-form-urlencoded',
      );
    });

    test('multipart wins over the untyped kinds', () {
      expect(
        selectMediaType(const ['application/xml', 'multipart/form-data']),
        'multipart/form-data',
      );
    });

    test('otherwise the first declared media type, in spec order', () {
      expect(
        selectMediaType(const ['text/plain', 'application/octet-stream']),
        'text/plain',
      );
    });
  });
}
