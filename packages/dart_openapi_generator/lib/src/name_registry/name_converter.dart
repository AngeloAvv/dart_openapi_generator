/// Converts a spec identifier (snake_case, kebab-case, or space-separated)
/// to a Dart PascalCase class name.
///
/// Examples:
///   `'my_pet_store'`   → `'MyPetStore'`
///   `'payment-method'` → `'PaymentMethod'`
///   `'user profile'`   → `'UserProfile'`
///   `'User'`           → `'User'` (already Pascal)
///   `'SCREAMING_SNAKE'`→ `'ScreamingSnake'`
///   `''`               → `''` (empty string preserved)
String toPascalCase(String specName) {
  if (specName.isEmpty) return specName;
  return specName
      .split(RegExp(r'[_\-\s]+'))
      .where((s) => s.isNotEmpty)
      .expand(_splitCamelBoundaries)
      .where((s) => s.isNotEmpty)
      .map((s) => s[0].toUpperCase() + s.substring(1).toLowerCase())
      .join();
}

/// Splits a camelCase or PascalCase segment at lowercase→UPPERCASE transitions.
///
/// Examples:
///   `'createPet'` → `['create', 'Pet']`
///   `'UserRequest'` → `['User', 'Request']`
///   `'SCREAMING'` → `['SCREAMING']` (all-caps: no split)
///   `'user'` → `['user']`
List<String> _splitCamelBoundaries(String s) =>
    s.split(RegExp(r'(?<=[a-z])(?=[A-Z])'));

/// Converts a spec identifier (snake_case, kebab-case, or space-separated)
/// to a Dart lowerCamelCase field name.
///
/// Examples:
///   `'created_at'`    → `'createdAt'`
///   `'user-id'`       → `'userId'`
///   `'FirstName'`     → `'firstname'` (normalizes via PascalCase intermediate)
///   `''`              → `''` (empty string preserved)
String toLowerCamelCase(String specName) {
  final pascal = toPascalCase(specName);
  if (pascal.isEmpty) return specName;
  return pascal[0].toLowerCase() + pascal.substring(1);
}

/// Converts a Dart PascalCase class name to snake_case for use as a filename
/// fragment.
///
/// Handles consecutive-capital sequences (e.g. `HTMLParser` → `html_parser`)
/// by inserting an underscore before the last capital of each all-caps run
/// before applying the standard lowercase→uppercase transition rule.
///
/// Examples:
///   `'PetStore'`   → `'pet_store'`
///   `'HTMLParser'` → `'html_parser'`
///   `'MyModel'`    → `'my_model'`
///
/// Do NOT use this for tags — use [tagToSnake] for tag → filename conversion.
String toSnakeCase(String className) =>
    className
        .replaceAllMapped(
          RegExp(r'([A-Z]+)([A-Z][a-z])'),
          (m) => '${m[1]!.toLowerCase()}_${m[2]!.toLowerCase()}',
        )
        .replaceAllMapped(
          RegExp(r'(?<=[a-z\d])([A-Z])'),
          (m) => '_${m[1]!.toLowerCase()}',
        )
        .toLowerCase();

/// Converts an OpenAPI tag to a snake_case filename fragment (space/hyphen →
/// underscore, full lowercase).
///
/// Tags are not PascalCase class names; do not use this for converting Dart
/// class names to filenames — use [toSnakeCase] for that purpose.
///
/// Examples:
///   `'PetStore'`   → `'petstore'`
///   `'pet store'`  → `'pet_store'`
///   `'pet-store'`  → `'pet_store'`
String tagToSnake(String tag) =>
    tag.trim().toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '_');
