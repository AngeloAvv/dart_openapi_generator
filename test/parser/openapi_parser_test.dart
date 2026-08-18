import 'package:dart_openapi_generator/src/date_time_converter.dart';
import 'package:dart_openapi_generator/src/generator/model_generator.dart';
import 'package:dart_openapi_generator/src/layout/model_layout.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/name_registry/name_registry.dart';
import 'package:dart_openapi_generator/src/parser/openapi_parser.dart';
import 'package:dart_openapi_generator/src/parser/source_map.dart';
import 'package:test/test.dart';

/// Regression coverage for the "inline request/response body schema is
/// registered by [NameRegistry] but never emitted by [ModelGenerator]" bug:
/// previously the generated service file would reference a class (e.g.
/// `CreateWidgetRequest`) that no model file ever defined, so the generated
/// package failed to compile for any spec using inline (non-`$ref`) bodies.
void main() {
  group('OpenApiParser — inline request/response body schemas', () {
    final rawMap = <String, dynamic>{
      'openapi': '3.0.3',
      'info': {'title': 'Test', 'version': '1.0.0'},
      'paths': {
        '/widgets': {
          'post': {
            'operationId': 'createWidget',
            'requestBody': {
              'content': {
                'application/json': {
                  'schema': {
                    'type': 'object',
                    'properties': {
                      'name': {'type': 'string'},
                    },
                    'required': ['name'],
                  },
                },
              },
            },
            'responses': {
              '200': {
                'description': 'OK',
                'content': {
                  'application/json': {
                    'schema': {
                      'type': 'object',
                      'properties': {
                        'id': {'type': 'string'},
                      },
                    },
                  },
                },
              },
            },
          },
        },
      },
    };

    test('inline object bodies are registered under the same computed name '
        'NameRegistry uses, and ModelGenerator emits a file for them', () {
      final document = const OpenApiParser().parse(rawMap, const SourceMap({}));

      expect(
        document.schemas.keys,
        containsAll(['CreateWidgetRequest', 'CreateWidgetResponse']),
      );
      expect(document.schemas['CreateWidgetRequest'], isA<ObjectSchema>());
      expect(document.schemas['CreateWidgetResponse'], isA<ObjectSchema>());

      final registry = buildNameRegistry(document);
      expect(
        registry.dartClassName('CreateWidgetRequest'),
        'CreateWidgetRequest',
      );
      expect(
        registry.dartClassName('CreateWidgetResponse'),
        'CreateWidgetResponse',
      );

      final modelFiles = ModelGenerator(
        registry,
        ModelLayout.build(document, registry),
        DateTimeConverter.iso8601,
      ).generate(document);
      expect(modelFiles.keys, contains('models/create_widget_request.dart'));
      expect(modelFiles.keys, contains('models/create_widget_response.dart'));
      expect(
        modelFiles['models/create_widget_request.dart'],
        contains('class CreateWidgetRequest'),
      );
      expect(
        modelFiles['models/create_widget_response.dart'],
        contains('class CreateWidgetResponse'),
      );
    });
  });
}
