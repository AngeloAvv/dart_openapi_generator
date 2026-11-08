import 'package:dart_openapi_generator/src/model/openapi_parse_exception.dart';
import 'package:dart_openapi_generator/src/model/spec_document.dart';
import 'package:dart_openapi_generator/src/parser/openapi_parser.dart';
import 'package:dart_openapi_generator/src/parser/source_map.dart';
import 'package:test/test.dart';

const _tenantId = {
  'name': 'X-Tenant-Id',
  'in': 'header',
  'required': true,
  'description': 'Tenant the request is scoped to.',
  'schema': {'type': 'string'},
};

const _itemId = {
  'name': 'itemId',
  'in': 'path',
  'required': true,
  'schema': {'type': 'string'},
};

const _ok = {
  '200': {'description': 'ok'},
};

SpecDocument _parse({
  Map<String, dynamic> paths = const {},
  Map<String, dynamic> parameters = const {'TenantId': _tenantId},
}) => const OpenApiParser().parse({
  'openapi': '3.0.3',
  'info': {'title': 'Test', 'version': '1.0.0'},
  'paths': paths,
  'components': {'parameters': parameters},
}, const SourceMap({}));

Map<String, dynamic> _ref(String name) => {
  r'$ref': '#/components/parameters/$name',
};

void main() {
  group('OperationParser — parameter \$ref', () {
    test('operation-level reference is resolved like the inline parameter', () {
      final viaRef = _parse(
        paths: {
          '/items/{itemId}': {
            'get': {
              'operationId': 'getItem',
              'parameters': [_ref('TenantId'), _itemId],
              'responses': _ok,
            },
          },
        },
      );
      final inline = _parse(
        paths: {
          '/items/{itemId}': {
            'get': {
              'operationId': 'getItem',
              'parameters': [_tenantId, _itemId],
              'responses': _ok,
            },
          },
        },
      );

      final params = viaRef.operations.single.parameters;
      expect(params.map((p) => p.name), ['X-Tenant-Id', 'itemId']);
      final tenant = params.first;
      expect(tenant.location, 'header');
      expect(tenant.required, isTrue);
      expect(tenant.description, 'Tenant the request is scoped to.');
      expect(
        params.map((p) => (p.name, p.location, p.required, p.description)),
        inline.operations.single.parameters.map(
          (p) => (p.name, p.location, p.required, p.description),
        ),
      );
    });

    test('path-level reference reaches every operation of the path', () {
      final doc = _parse(
        paths: {
          '/items': {
            'parameters': [_ref('TenantId')],
            'get': {'operationId': 'listItems', 'responses': _ok},
            'post': {'operationId': 'createItem', 'responses': _ok},
          },
        },
      );

      expect(doc.operations, hasLength(2));
      for (final op in doc.operations) {
        expect(op.parameters.single.name, 'X-Tenant-Id');
        expect(op.parameters.single.location, 'header');
      }
    });

    test('one component can be referenced from several operations', () {
      final doc = _parse(
        paths: {
          '/a': {
            'get': {
              'operationId': 'getA',
              'parameters': [_ref('TenantId')],
              'responses': _ok,
            },
          },
          '/b': {
            'get': {
              'operationId': 'getB',
              'parameters': [_ref('TenantId')],
              'responses': _ok,
            },
          },
        },
      );

      expect(
        doc.operations.map((o) => o.parameters.single.name),
        everyElement('X-Tenant-Id'),
      );
    });

    test('an operation-level reference overrides the path-level one', () {
      final doc = _parse(
        parameters: {
          'TenantId': _tenantId,
          'OptionalTenantId': {..._tenantId, 'required': false},
        },
        paths: {
          '/items': {
            'parameters': [_ref('TenantId')],
            'get': {
              'operationId': 'listItems',
              'parameters': [_ref('OptionalTenantId')],
              'responses': _ok,
            },
          },
        },
      );

      final param = doc.operations.single.parameters.single;
      expect(param.name, 'X-Tenant-Id');
      expect(param.required, isFalse);
    });

    test('a component that is itself a reference is followed', () {
      final doc = _parse(
        parameters: {'TenantId': _tenantId, 'Alias': _ref('TenantId')},
        paths: {
          '/items': {
            'get': {
              'operationId': 'listItems',
              'parameters': [_ref('Alias')],
              'responses': _ok,
            },
          },
        },
      );

      expect(doc.operations.single.parameters.single.name, 'X-Tenant-Id');
    });

    test('a reference to a missing component throws with its pointer', () {
      expect(
        () => _parse(
          paths: {
            '/items': {
              'get': {
                'operationId': 'listItems',
                'parameters': [_ref('Missing')],
                'responses': _ok,
              },
            },
          },
        ),
        throwsA(
          isA<OpenApiParseException>()
              .having(
                (e) => e.jsonPointer,
                'jsonPointer',
                '#/paths/~1items/get/parameters/0',
              )
              .having((e) => e.message, 'message', contains('Missing')),
        ),
      );
    });

    test('a path-level reference to a missing component throws', () {
      expect(
        () => _parse(
          paths: {
            '/items': {
              'parameters': [_ref('Missing')],
              'get': {'operationId': 'listItems', 'responses': _ok},
            },
          },
        ),
        throwsA(
          isA<OpenApiParseException>().having(
            (e) => e.jsonPointer,
            'jsonPointer',
            '#/paths/~1items/parameters/0',
          ),
        ),
      );
    });

    test('a circular reference chain throws instead of looping', () {
      expect(
        () => _parse(
          parameters: {'A': _ref('B'), 'B': _ref('A')},
          paths: {
            '/items': {
              'get': {
                'operationId': 'listItems',
                'parameters': [_ref('A')],
                'responses': _ok,
              },
            },
          },
        ),
        throwsA(isA<OpenApiParseException>()),
      );
    });

    test('an external reference is rejected', () {
      expect(
        () => _parse(
          paths: {
            '/items': {
              'get': {
                'operationId': 'listItems',
                'parameters': [
                  {r'$ref': 'other.yaml#/components/parameters/TenantId'},
                ],
                'responses': _ok,
              },
            },
          },
        ),
        throwsA(isA<OpenApiParseException>()),
      );
    });
  });
}
