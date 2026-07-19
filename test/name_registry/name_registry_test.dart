import 'package:dart_openapi_generator/src/model/openapi_parse_exception.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/model/spec_document.dart';
import 'package:dart_openapi_generator/src/name_registry/name_registry.dart';
import 'package:test/test.dart';

SpecDocument _makeDoc({
  Map<String, SchemaObject> schemas = const {},
  List<OperationItem> operations = const [],
}) => SpecDocument(
  specVersion: '3.0.3',
  title: 'Test',
  baseUrl: '',
  schemas: schemas,
  operations: operations,
  securitySchemes: const {},
);

void main() {
  group('NameRegistry (NAME-01)', () {
    test('is immutable — dartClassName returns consistent values', () {
      final doc = _makeDoc(
        schemas: {'User': const ObjectSchema(properties: [], required: [])},
      );
      final registry = buildNameRegistry(doc);
      expect(registry.dartClassName('User'), equals('User'));
      expect(registry.dartClassName('User'), equals('User'));
    });

    test('dartClassName throws StateError for unknown name', () {
      final registry = buildNameRegistry(_makeDoc());
      expect(() => registry.dartClassName('Unknown'), throwsStateError);
    });

    test('duplicate generated names throw OpenApiParseException (NAME-05)', () {
      // Component schema 'UserRequest' AND 'user_request' both → 'UserRequest'
      final doc = _makeDoc(
        schemas: {
          'UserRequest': const ObjectSchema(properties: [], required: []),
          'user_request': const ObjectSchema(properties: [], required: []),
        },
      );
      expectLater(
        () => buildNameRegistry(doc),
        throwsA(
          isA<OpenApiParseException>().having(
            (e) => e.message,
            'message',
            contains('Duplicate'),
          ),
        ),
      );
    });
  });

  group('NameRegistry field names (NAME-04)', () {
    test('field registered for ObjectSchema properties', () {
      final doc = _makeDoc(
        schemas: {
          'User': ObjectSchema(
            properties: [
              const SchemaProperty(
                specName: 'created_at',
                schema: PrimitiveSchema(primitiveType: 'string'),
                isRequired: true,
              ),
            ],
            required: ['created_at'],
          ),
        },
      );
      final registry = buildNameRegistry(doc);
      expect(registry.dartFieldName('User', 'created_at'), equals('createdAt'));
    });

    test('inline request body schema named <OperationId>Request (NAME-04)', () {
      // An operation with operationId 'createPet' and a jsonSchema requestBody
      // produces a schema registered under the name 'CreatePetRequest'.
      final requestSchema = const ObjectSchema(properties: [], required: []);
      final doc = SpecDocument(
        specVersion: '3.0.3',
        title: 'Test',
        baseUrl: '',
        schemas: const {},
        operations: [
          OperationItem(
            operationId: 'createPet',
            method: 'post',
            path: '/pets',
            parameters: const [],
            requestBody: RequestBodyObject(
              required: true,
              jsonSchema:
                  requestSchema, // NOTE: uses jsonSchema, not content map
            ),
            responses: const {},
            tags: const [],
            security: const [],
            additionalMethods: const [],
          ),
        ],
        securitySchemes: const {},
      );
      final registry = buildNameRegistry(doc);
      expect(
        registry.dartClassName('CreatePetRequest'),
        equals('CreatePetRequest'),
      );
    });
  });
}
