import 'package:dart_openapi_generator/src/name_registry/keyword_escaper.dart';
import 'package:test/test.dart';

void main() {
  group('escapeKeyword (NAME-03)', () {
    test('class → class_', () => expect(escapeKeyword('class'), 'class_'));
    test('enum → enum_', () => expect(escapeKeyword('enum'), 'enum_'));
    test('null → null_', () => expect(escapeKeyword('null'), 'null_'));
    test('return → return_', () => expect(escapeKeyword('return'), 'return_'));
    test('async → async_', () => expect(escapeKeyword('async'), 'async_'));
    test('await → await_', () => expect(escapeKeyword('await'), 'await_'));
    test(
      'default → default_',
      () => expect(escapeKeyword('default'), 'default_'),
    );
    test('new → new_', () => expect(escapeKeyword('new'), 'new_'));
    test(
      'userId (non-keyword) → unchanged',
      () => expect(escapeKeyword('userId'), 'userId'),
    );
    test(
      'MyClass (non-keyword) → unchanged',
      () => expect(escapeKeyword('MyClass'), 'MyClass'),
    );
    test('kDartKeywords contains expected entries', () {
      expect(
        kDartKeywords,
        containsAll([
          'class',
          'enum',
          'null',
          'return',
          'async',
          'await',
          'new',
          'default',
          'base',
          'when',
        ]),
      );
    });
    test('base → base_', () => expect(escapeKeyword('base'), 'base_'));
    test('when → when_', () => expect(escapeKeyword('when'), 'when_'));
  });
}
