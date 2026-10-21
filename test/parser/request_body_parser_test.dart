import 'package:dart_openapi_generator/src/model/media_type.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/model/spec_document.dart';
import 'package:dart_openapi_generator/src/parser/openapi_parser.dart';
import 'package:dart_openapi_generator/src/parser/source_map.dart';
import 'package:test/test.dart';

/// Parses a spec made of a single `POST /things` operation with the given
/// `requestBody` and `responses`.
OperationItem _parseOperation({
  Map<String, dynamic>? requestBody,
  Map<String, dynamic> responses = const {
    '204': {'description': 'ok'},
  },
  String openapi = '3.0.3',
}) {
  final document = const OpenApiParser().parse({
    'openapi': openapi,
    'info': {'title': 'Test', 'version': '1.0.0'},
    'paths': {
      '/things': {
        'post': {
          'operationId': 'createThing',
          if (requestBody != null) 'requestBody': requestBody,
          'responses': responses,
        },
      },
    },
  }, const SourceMap({}));
  return document.operations.single;
}

const _objectSchema = {
  'type': 'object',
  'properties': {
    'name': {'type': 'string'},
  },
};

void main() {
  group('OperationParser — request body media type', () {
    test('a url-encoded body keeps its media type and its schema', () {
      final op = _parseOperation(
        requestBody: {
          'required': true,
          'content': {
            'application/x-www-form-urlencoded': {'schema': _objectSchema},
          },
        },
      );
      final body = op.requestBody!;
      expect(body.mediaType, 'application/x-www-form-urlencoded');
      expect(body.kind, MediaTypeKind.formUrlEncoded);
      expect(body.required, isTrue);
      expect(body.schema, isA<ObjectSchema>());
    });

    test('a multipart body keeps its media type and its schema', () {
      final op = _parseOperation(
        requestBody: {
          'content': {
            'multipart/form-data': {'schema': _objectSchema},
          },
        },
      );
      expect(op.requestBody!.kind, MediaTypeKind.multipart);
      expect(op.requestBody!.schema, isA<ObjectSchema>());
    });

    test('JSON is chosen over the form kinds when both are declared', () {
      final op = _parseOperation(
        requestBody: {
          'content': {
            'application/x-www-form-urlencoded': {'schema': _objectSchema},
            'application/json': {'schema': _objectSchema},
          },
        },
      );
      expect(op.requestBody!.mediaType, 'application/json');
    });

    test('a JSON media type with parameters is parsed as JSON', () {
      final op = _parseOperation(
        requestBody: {
          'content': {
            'application/json; charset=utf-8': {'schema': _objectSchema},
          },
        },
      );
      expect(op.requestBody!.kind, MediaTypeKind.json);
      expect(op.requestBody!.schema, isA<ObjectSchema>());
    });

    test('the schema of an untyped media type is not parsed', () {
      // `anyOf` would throw if it were parsed: the XML schema never reaches
      // the generated code, so it must not break the build either.
      final op = _parseOperation(
        requestBody: {
          'content': {
            'application/xml': {
              'schema': {
                'anyOf': [
                  {'type': 'string'},
                ],
              },
            },
          },
        },
      );
      expect(op.requestBody!.mediaType, 'application/xml');
      expect(op.requestBody!.kind, MediaTypeKind.text);
      expect(op.requestBody!.schema, isNull);
    });

    test('an empty content map has no media type', () {
      final op = _parseOperation(requestBody: {'content': <String, dynamic>{}});
      expect(op.requestBody!.mediaType, isNull);
      expect(op.requestBody!.kind, isNull);
    });

    test('the Encoding Object map of the chosen media type is parsed', () {
      final op = _parseOperation(
        requestBody: {
          'content': {
            'application/x-www-form-urlencoded': {
              'schema': _objectSchema,
              'encoding': {
                'tags': {
                  'style': 'pipeDelimited',
                  'explode': false,
                  'allowReserved': true,
                },
                'file': {
                  'contentType': 'image/png',
                  'headers': {
                    'X-Rate-Limit': {
                      'schema': {'type': 'integer'},
                    },
                  },
                },
              },
            },
          },
        },
      );
      final encoding = op.requestBody!.encoding;
      expect(encoding.keys, unorderedEquals(['tags', 'file']));
      expect(encoding['tags']!.style, 'pipeDelimited');
      expect(encoding['tags']!.explode, isFalse);
      expect(encoding['tags']!.allowReserved, isTrue);
      expect(encoding['tags']!.contentType, isNull);
      expect(encoding['file']!.contentType, 'image/png');
      expect(encoding['file']!.hasHeaders, isTrue);
    });
  });

  group('OperationParser — response media type', () {
    test('a text/plain response keeps its media type, without a schema', () {
      final op = _parseOperation(
        responses: {
          '200': {
            'description': 'ok',
            'content': {
              'text/plain': {
                'schema': {'type': 'string'},
              },
            },
          },
        },
      );
      final response = op.responses['200']!;
      expect(response.mediaType, 'text/plain');
      expect(response.kind, MediaTypeKind.text);
      expect(response.schema, isNull);
    });

    test('an application/problem+json response is parsed as JSON', () {
      final op = _parseOperation(
        responses: {
          '422': {
            'description': 'invalid',
            'content': {
              'application/problem+json': {'schema': _objectSchema},
            },
          },
        },
      );
      expect(op.responses['422']!.kind, MediaTypeKind.json);
      expect(op.responses['422']!.schema, isA<ObjectSchema>());
    });

    test('a response without content has no media type', () {
      final op = _parseOperation();
      expect(op.responses['204']!.mediaType, isNull);
      expect(op.responses['204']!.kind, isNull);
    });
  });

  group('SchemaParser — binary content', () {
    SchemaObject parseBodyProperty(
      Map<String, dynamic> property, {
      String openapi = '3.0.3',
    }) {
      final op = _parseOperation(
        openapi: openapi,
        requestBody: {
          'content': {
            'multipart/form-data': {
              'schema': {
                'type': 'object',
                'properties': {'file': property},
              },
            },
          },
        },
      );
      return (op.requestBody!.schema! as ObjectSchema).properties.single.schema;
    }

    test('format: binary is binary', () {
      final schema = parseBodyProperty({'type': 'string', 'format': 'binary'});
      expect(isBinarySchema(schema), isTrue);
    });

    test('an array of format: binary is binary', () {
      final schema = parseBodyProperty({
        'type': 'array',
        'items': {'type': 'string', 'format': 'binary'},
      });
      expect(isBinarySchema(schema), isTrue);
    });

    test('3.1 contentMediaType without contentEncoding is binary', () {
      final schema = parseBodyProperty({
        'type': 'string',
        'contentMediaType': 'image/png',
      }, openapi: '3.1.0');
      expect(isBinarySchema(schema), isTrue);
      expect((schema as PrimitiveSchema).contentMediaType, 'image/png');
    });

    test('3.1 contentMediaType with contentEncoding is text', () {
      final schema = parseBodyProperty({
        'type': 'string',
        'contentMediaType': 'image/png',
        'contentEncoding': 'base64',
      }, openapi: '3.1.0');
      expect(isBinarySchema(schema), isFalse);
    });

    test('format: byte (base64 text) is not binary', () {
      final schema = parseBodyProperty({'type': 'string', 'format': 'byte'});
      expect(isBinarySchema(schema), isFalse);
    });
  });
}
