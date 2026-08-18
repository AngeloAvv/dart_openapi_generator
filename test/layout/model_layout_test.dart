import 'package:dart_openapi_generator/src/layout/model_layout.dart';
import 'package:dart_openapi_generator/src/layout/one_of_plan.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/model/spec_document.dart';
import 'package:dart_openapi_generator/src/name_registry/name_registry.dart';
import 'package:test/test.dart';

SpecDocument _doc(Map<String, SchemaObject> schemas) => SpecDocument(
  specVersion: '3.0.3',
  title: 'Test',
  baseUrl: '',
  schemas: schemas,
  operations: const [],
  securitySchemes: const {},
);

ModelLayout _layout(SpecDocument doc) =>
    ModelLayout.build(doc, buildNameRegistry(doc));

ObjectSchema _obj(String name) =>
    ObjectSchema(name: name, properties: const [], required: const []);

OneOfSchema _oneOf(String name, List<SchemaObject> variants) =>
    OneOfSchema(name: name, variants: variants);

void main() {
  group('ModelLayout', () {
    test('a schema not involved in any oneOf keeps its own file', () {
      final doc = _doc({
        'Customer': _obj('Customer'),
        'Agency': _obj('Agency'),
      });
      final layout = _layout(doc);

      expect(layout.fileFor('Customer'), 'customer.dart');
      expect(layout.fileFor('Agency'), 'agency.dart');
      expect(layout.isCluster('customer.dart'), isFalse);
      expect(layout.files, ['agency.dart', 'customer.dart']);
    });

    test(r'a $ref branch shares its wrapper file', () {
      final doc = _doc({
        'Customer': _obj('Customer'),
        'Driver': _obj('Driver'),
        'RegisterRequest': _oneOf('RegisterRequest', [
          _obj('Customer'),
          _obj('Driver'),
        ]),
      });
      final layout = _layout(doc);

      expect(layout.fileFor('Customer'), 'register_request.dart');
      expect(layout.fileFor('Driver'), 'register_request.dart');
      expect(layout.fileFor('RegisterRequest'), 'register_request.dart');
      expect(layout.isCluster('register_request.dart'), isTrue);
      expect(layout.wrappersOf('register_request.dart'), ['RegisterRequest']);
      // Wrappers first, then members, both alphabetical.
      expect(layout.membersOf('register_request.dart'), [
        'RegisterRequest',
        'Customer',
        'Driver',
      ]);
    });

    test('two unions sharing a branch collapse into one file', () {
      final doc = _doc({
        'Customer': _obj('Customer'),
        'Driver': _obj('Driver'),
        'RegisterRequest': _oneOf('RegisterRequest', [
          _obj('Customer'),
          _obj('Driver'),
        ]),
        'RegisterResponse': _oneOf('RegisterResponse', [
          _obj('Customer'),
          _obj('Driver'),
        ]),
      });
      final layout = _layout(doc);

      expect(layout.files, ['register_request.dart']);
      expect(layout.wrappersOf('register_request.dart'), [
        'RegisterRequest',
        'RegisterResponse',
      ]);
    });

    test('clusters merge transitively', () {
      // A|B and B|C must end up together, or B would be declared twice.
      final doc = _doc({
        'A': _obj('A'),
        'B': _obj('B'),
        'C': _obj('C'),
        'Ab': _oneOf('Ab', [_obj('A'), _obj('B')]),
        'Bc': _oneOf('Bc', [_obj('B'), _obj('C')]),
      });
      final layout = _layout(doc);

      expect(layout.files, ['ab.dart']);
      expect(layout.membersOf('ab.dart'), ['Ab', 'Bc', 'A', 'B', 'C']);
    });

    test('disjoint unions keep separate files', () {
      final doc = _doc({
        'A': _obj('A'),
        'B': _obj('B'),
        'Ua': _oneOf('Ua', [_obj('A')]),
        'Ub': _oneOf('Ub', [_obj('B')]),
      });
      final layout = _layout(doc);

      expect(layout.files, ['ua.dart', 'ub.dart']);
      expect(layout.fileFor('A'), 'ua.dart');
      expect(layout.fileFor('B'), 'ub.dart');
    });

    test('non class-shaped branches are not merged', () {
      // An enum or an array cannot implement the wrapper, so it stays in its
      // own file and is held by a generated value class instead.
      final doc = _doc({
        'Colour': const EnumSchema(
          name: 'Colour',
          enumType: 'string',
          values: ['red'],
        ),
        'Thing': _oneOf('Thing', [
          const EnumSchema(name: 'Colour', enumType: 'string', values: ['red']),
        ]),
      });
      final layout = _layout(doc);

      expect(layout.fileFor('Colour'), 'colour.dart');
      expect(layout.fileFor('Thing'), 'thing.dart');
    });

    test('the layout does not depend on schema declaration order', () {
      final forward = _layout(
        _doc({
          'Customer': _obj('Customer'),
          'Zeta': _oneOf('Zeta', [_obj('Customer')]),
          'Alpha': _oneOf('Alpha', [_obj('Customer')]),
        }),
      );
      final reversed = _layout(
        _doc({
          'Alpha': _oneOf('Alpha', [_obj('Customer')]),
          'Zeta': _oneOf('Zeta', [_obj('Customer')]),
          'Customer': _obj('Customer'),
        }),
      );

      expect(forward.files, reversed.files);
      expect(forward.fileFor('Customer'), reversed.fileFor('Customer'));
      expect(forward.fileFor('Customer'), 'alpha.dart');
    });

    test('fileFor is total: an unknown schema falls back to its own file', () {
      // ServiceGenerator used to read the old empty-string return as "no
      // import" and emit a file referencing a type it never imported.
      final doc = _doc({'Customer': _obj('Customer')});
      final layout = _layout(doc);

      expect(layout.fileOf('Customer'), 'customer.dart');
      expect(layout.fileOf('Nope'), isNull);
      expect(layout.resolveFile('Customer'), 'customer.dart');
      expect(layout.fileFor('Customer'), 'customer.dart');
    });

    test(
      r'unionsImplementedBy lists every wrapper a $ref branch belongs to',
      () {
        final doc = _doc({
          'Customer': _obj('Customer'),
          'RegisterRequest': _oneOf('RegisterRequest', [_obj('Customer')]),
          'RegisterResponse': _oneOf('RegisterResponse', [_obj('Customer')]),
        });
        final layout = _layout(doc);

        expect(layout.unionsImplementedBy('Customer'), [
          'RegisterRequest',
          'RegisterResponse',
        ]);
        expect(layout.unionsImplementedBy('RegisterRequest'), isEmpty);
      },
    );

    test('isPolymorphicUnion is backed by the shared oneOf plan', () {
      final doc = _doc({
        'Objects': _oneOf('Objects', [_obj('A')]),
        'A': _obj('A'),
        'Mixed': _oneOf('Mixed', [
          _obj('A'),
          const PrimitiveSchema(primitiveType: 'string'),
        ]),
      });
      final layout = _layout(doc);

      expect(layout.isPolymorphicUnion('Mixed'), isTrue);
      expect(layout.isPolymorphicUnion('Objects'), isFalse);
      expect(layout.isPolymorphicUnion('A'), isFalse);
      expect(layout.oneOfPlan.isPolymorphic('Mixed'), isTrue);
    });

    test(r'a $ref branch outside components/schemas is skipped, not fatal', () {
      final doc = _doc({
        'Thing': _oneOf('Thing', [_obj('Elsewhere')]),
      });
      final layout = _layout(doc);

      expect(layout.files, ['thing.dart']);
      expect(layout.membersOf('thing.dart'), ['Thing']);
      expect(
        layout.oneOfPlan.branchesOf('Thing').single,
        isA<SkippedBranch>().having(
          (b) => b.reason,
          'reason',
          contains('Elsewhere'),
        ),
      );
    });
  });
}
