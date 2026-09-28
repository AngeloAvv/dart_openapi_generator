/// Class modifier applied to generated model classes.
enum ModelClassModifier {
  /// `final class Foo { ... }` — forbids `extends` and `implements` outside
  /// the declaring library, so test doubles are not possible.
  final$,

  /// `class Foo { ... }` — no modifier.
  none,
}
