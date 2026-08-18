import '../model/schema_object.dart';
import '../model/spec_document.dart';
import '../name_registry/name_converter.dart';

/// One branch of a `oneOf`, classified once for the whole pipeline.
///
/// [index] is the branch's position in `OneOfSchema.variants`, preserved so
/// that generated names (`<Wrapper>Variant<index>`) and warning messages stay
/// stable when a branch in the middle is skipped.
sealed class OneOfBranch {
  final int index;

  const OneOfBranch(this.index);
}

/// A `$ref` branch pointing at a class-shaped component that exists in
/// `#/components/schemas`.
///
/// The component is reused as-is: it is declared once, in the wrapper's
/// library, and gains an `implements <Wrapper>` clause.
final class ReusedRefBranch extends OneOfBranch {
  /// The component's own spec name — already registered in [NameRegistry].
  final String specName;

  final SchemaObject schema;

  const ReusedRefBranch(super.index, this.specName, this.schema);
}

/// An anonymous inline `object` branch, emitted as a `<Wrapper>Variant<index>`
/// subclass of the wrapper.
final class InlineObjectBranch extends OneOfBranch {
  /// Synthesised spec name, unique across the document.
  final String specName;

  final ObjectSchema schema;

  const InlineObjectBranch(super.index, this.specName, this.schema);
}

/// A branch that cannot implement the wrapper — an array, a primitive, an
/// enum, or any named non-class-shaped component.
///
/// It is emitted as a generated class holding the decoded payload in a single
/// `value` field. A wrapper with at least one of these decodes from a raw
/// payload rather than from a JSON object (see [OneOfPlan.isPolymorphic]).
final class ValueBranch extends OneOfBranch {
  /// Synthesised spec name, unique across the document.
  final String specName;

  final SchemaObject schema;

  const ValueBranch(super.index, this.specName, this.schema);
}

/// A branch that contributes nothing to the generated code: a `$ref` cycle, or
/// a `$ref` whose target is not a component schema.
///
/// [reason] is the ready-to-emit advisory message; the generator forwards it
/// verbatim to its `onWarning` sink.
final class SkippedBranch extends OneOfBranch {
  final String reason;

  const SkippedBranch(super.index, this.reason);
}

/// The single source of truth for how every `oneOf` branch in a document is
/// treated.
///
/// The same four-way decision — reuse the referenced component, emit an inline
/// subclass, wrap a non-object payload in a value class, or skip the branch —
/// used to be written by hand in the name registry, in [ModelLayout] and twice
/// in `ModelGenerator`. Those copies could (and did) disagree, which is how a
/// `$ref` outside `#/components/schemas` reached the registry and crashed the
/// build with an internal `StateError`. Classification now happens exactly
/// once, here, and everything downstream reads the result.
///
/// Build order for a document is therefore:
/// [OneOfPlan.build] → `buildNameRegistry` → [ModelLayout.build] → generators.
final class OneOfPlan {
  final Map<String, List<OneOfBranch>> _branchesByWrapper;
  final Map<String, String> _synthesizedSources;

  const OneOfPlan._(this._branchesByWrapper, this._synthesizedSources);

  /// Classifies every `oneOf` branch in [document].
  ///
  /// Wrappers are visited in sorted order so that the synthesised names — and
  /// therefore the disambiguation suffixes below — never depend on the order
  /// the schemas happen to appear in the spec.
  factory OneOfPlan.build(SpecDocument document) {
    // Every Dart class name the user's own schemas already claim. Comparison
    // happens on the PascalCase form because that is what actually collides in
    // the generated code: `foo_string` and `FooString` are one class name.
    final claimed = <String>{
      for (final key in document.schemas.keys) toPascalCase(key),
    };

    /// Reserves [base], appending `2`, `3`, … until the PascalCase form is
    /// free. The synthesised name is ours, not the user's: it yields to a real
    /// component rather than failing the build over a name the user cannot
    /// find anywhere in their spec.
    String claim(String base) {
      var candidate = base;
      var attempt = 1;
      while (!claimed.add(toPascalCase(candidate))) {
        attempt++;
        candidate = '$base$attempt';
      }
      return candidate;
    }

    final branchesByWrapper = <String, List<OneOfBranch>>{};
    final synthesizedSources = <String, String>{};

    final wrapperNames =
        document.schemas.entries
            .where((e) => e.value is OneOfSchema)
            .map((e) => e.key)
            .toList()
          ..sort();

    for (final wrapper in wrapperNames) {
      final schema = document.schemas[wrapper]! as OneOfSchema;
      final branches = <OneOfBranch>[];

      for (var i = 0; i < schema.variants.length; i++) {
        final variant = schema.variants[i];

        if (isCyclicRef(variant)) {
          branches.add(
            SkippedBranch(
              i,
              'oneOf variant $i of "$wrapper" is a cyclic reference; skipped.',
            ),
          );
          continue;
        }

        final refName = variant.name;
        if (refName != null && _isClassShaped(variant)) {
          if (document.schemas.containsKey(refName)) {
            branches.add(ReusedRefBranch(i, refName, variant));
          } else {
            branches.add(
              SkippedBranch(
                i,
                'oneOf variant $i of "$wrapper" resolves to "$refName", which '
                'is not a schema under #/components/schemas; the branch is '
                'skipped and will not be decodable. Move the referenced schema '
                'into components/schemas.',
              ),
            );
          }
          continue;
        }

        final specName = claim(
          variant is ObjectSchema
              ? '${wrapper}Variant$i'
              : '$wrapper${_typeSuffix(variant, i)}',
        );
        synthesizedSources[specName] = '#/components/schemas/$wrapper/oneOf/$i';
        branches.add(
          variant is ObjectSchema
              ? InlineObjectBranch(i, specName, variant)
              : ValueBranch(i, specName, variant),
        );
      }

      branchesByWrapper[wrapper] = List.unmodifiable(branches);
    }

    return OneOfPlan._(
      Map.unmodifiable(branchesByWrapper),
      Map.unmodifiable(synthesizedSources),
    );
  }

  /// Spec names of every `oneOf` wrapper in the document, sorted.
  List<String> get wrapperSpecNames => _branchesByWrapper.keys.toList()..sort();

  /// The classified branches of [wrapperSpecName], in spec order. Empty for a
  /// schema that is not a `oneOf`.
  List<OneOfBranch> branchesOf(String wrapperSpecName) =>
      _branchesByWrapper[wrapperSpecName] ?? const [];

  /// Synthesised spec name → the JSON pointer it was derived from.
  ///
  /// Consumed by `buildNameRegistry`, which registers these alongside the
  /// user's own schema names. Every name here is already guaranteed unique
  /// against the document's schema keys.
  Map<String, String> get synthesizedSpecNames => _synthesizedSources;

  /// Whether [wrapperSpecName] has a branch that is not a JSON object.
  ///
  /// Such a union cannot promise `Map<String, dynamic>` from `toJson`, so the
  /// generated wrapper and the service call sites widen to `Object?`.
  bool isPolymorphic(String wrapperSpecName) =>
      branchesOf(wrapperSpecName).any((b) => b is ValueBranch);
}

/// Whether [schema] can be declared as a Dart class that `implements` a sealed
/// wrapper. Enums, arrays and primitives cannot, so they are held by value.
bool _isClassShaped(SchemaObject schema) =>
    schema is ObjectSchema || schema is AllOfSchema || schema is OneOfSchema;

/// Name fragment appended to the wrapper name for a value-held branch:
/// `String`, `Int`, `Double`, `Bool`, `DateTime`, `<Item>List`, or the
/// component's own name when the branch is a named `$ref`.
String _typeSuffix(SchemaObject schema, int index) {
  if (schema.name != null) return schema.name!;
  return switch (schema) {
    ArraySchema() => '${_typeSuffix(schema.items, index)}List',
    PrimitiveSchema() => switch (schema.primitiveType) {
      'string' => schema.format == 'date-time' ? 'DateTime' : 'String',
      'integer' => 'Int',
      'number' => 'Double',
      'boolean' => 'Bool',
      _ => 'Variant$index',
    },
    _ => 'Variant$index',
  };
}
