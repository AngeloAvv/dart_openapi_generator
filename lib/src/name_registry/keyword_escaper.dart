/// Dart reserved words and built-in identifiers that require escaping in
/// generated code.
///
/// Identifiers colliding with any entry in this set are escaped by appending
/// a trailing underscore (e.g. `class` → `class_`, `default` → `default_`).
///
/// Covers Categories 1–3 from the Dart language specification:
///   - Category 1: Reserved words (compiler ERROR if used as identifier)
///   - Category 2: Built-in identifiers (contextual issues)
///   - Category 3: Contextual keywords (async/sync contexts)
///
/// Excludes Category 4 (core type names like `String`, `int`) which are valid
/// as user-defined type names in most contexts.
const Set<String> kDartKeywords = {
  // Category 1 — Reserved words (MUST escape)
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue',
  'default', 'do', 'else', 'enum', 'extends', 'false', 'final',
  'finally', 'for', 'if', 'in', 'is', 'new', 'null', 'rethrow',
  'return', 'super', 'switch', 'this', 'throw', 'true', 'try',
  'var', 'void', 'while', 'with',
  // Category 2 — Built-in identifiers (SHOULD escape)
  'abstract', 'as', 'base', 'covariant', 'deferred', 'dynamic', 'export',
  'extension', 'external', 'factory', 'Function', 'get', 'hide',
  'implements', 'import', 'interface', 'late', 'library', 'mixin',
  'on', 'operator', 'part', 'required', 'sealed', 'set', 'show',
  'static', 'typedef',
  // Category 3 — Contextual keywords (async context issues)
  'async', 'await', 'sync', 'yield',
  // Dart 3.0 pattern-matching guard keyword
  'when',
};

/// Escapes [identifier] if it collides with a Dart reserved word or keyword.
///
/// Appends a trailing underscore: `class` → `class_`, `default` → `default_`.
/// Returns [identifier] unchanged if it is not in [kDartKeywords].
String escapeKeyword(String identifier) =>
    kDartKeywords.contains(identifier) ? '${identifier}_' : identifier;
