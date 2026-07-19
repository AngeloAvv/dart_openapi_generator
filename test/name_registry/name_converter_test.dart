import 'package:dart_openapi_generator/src/name_registry/name_converter.dart';
import 'package:test/test.dart';

void main() {
  group('toPascalCase (NAME-02)', () {
    test(
      'snake_case → PascalCase',
      () => expect(toPascalCase('my_schema'), 'MySchema'),
    );
    test(
      'kebab-case → PascalCase',
      () => expect(toPascalCase('payment-method'), 'PaymentMethod'),
    );
    test(
      'space separated → PascalCase',
      () => expect(toPascalCase('user profile'), 'UserProfile'),
    );
    test(
      'already PascalCase → preserved',
      () => expect(toPascalCase('User'), 'User'),
    );
    test(
      'SCREAMING_SNAKE → PascalCase',
      () => expect(toPascalCase('SCREAMING_SNAKE'), 'ScreamingSnake'),
    );
    test('single word lowercase', () => expect(toPascalCase('user'), 'User'));
    test('empty string → empty string', () => expect(toPascalCase(''), ''));
  });

  group('toLowerCamelCase (NAME-02)', () {
    test(
      'snake_case → lowerCamelCase',
      () => expect(toLowerCamelCase('created_at'), 'createdAt'),
    );
    test(
      'kebab-case → lowerCamelCase',
      () => expect(toLowerCamelCase('user-id'), 'userId'),
    );
    test(
      'single word → lowercase',
      () => expect(toLowerCamelCase('Name'), 'name'),
    );
    test('empty string → empty string', () => expect(toLowerCamelCase(''), ''));
  });
}
