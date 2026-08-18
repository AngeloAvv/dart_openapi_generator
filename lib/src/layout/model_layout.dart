import '../model/spec_document.dart';
import '../name_registry/name_converter.dart';
import '../name_registry/name_registry.dart';
import 'one_of_plan.dart';

/// The document-derived facts both generators need about `oneOf`: which file
/// declares each schema, which classes a reused branch implements, and which
/// wrappers can decode a non-object payload.
///
/// Built once per document by the caller and injected, exactly like
/// [NameRegistry] — the generators stay immutable configuration objects.
///
/// Most schemas get their own file (`models/<snake_name>.dart`), exactly as
/// before. The exception is `oneOf`: a `oneOf` wrapper is emitted as a
/// `sealed class`, and Dart only allows a sealed type to be implemented from
/// within the same library. A `oneOf` branch that is a `$ref` to a component
/// schema is therefore emitted in the SAME file as its wrapper — together they
/// form a *cluster*.
///
/// Clusters merge transitively: if two `oneOf` wrappers share a branch (the
/// common request/response pair of one endpoint), all three schemas land in one
/// file. This is what allows a shared component to belong to several unions —
/// `implements` accepts multiple supertypes, `extends` would not.
///
/// Cluster file names are a pure function of the cluster's members (the
/// alphabetically first wrapper), so regenerating an unchanged spec always
/// produces the same layout.
///
/// Every `oneOf` decision comes from the injected [OneOfPlan]; this class never
/// re-classifies a branch on its own.
final class ModelLayout {
  /// specName → file name relative to `models/` (e.g. `'customer.dart'`).
  final Map<String, String> _fileBySpecName;

  /// file name → spec names declared in it, wrappers first, then members.
  final Map<String, List<String>> _membersByFile;

  /// file name → `oneOf` wrapper spec names declared in it (empty for
  /// single-schema files).
  final Map<String, List<String>> _wrappersByFile;

  /// specName of a reused `$ref` branch → Dart class names of the wrappers it
  /// is a branch of, sorted. This is the `implements` clause of that class.
  final Map<String, List<String>> _unionsBySpecName;

  /// Dart class name of a `oneOf` wrapper → its spec name. Bridges the
  /// class-name key space [isPolymorphicUnion] is queried with back to the
  /// spec-name key space everything else uses.
  final Map<String, String> _wrapperSpecByClassName;

  /// The document's `oneOf` classification, shared with the name registry and
  /// read back by [ModelGenerator].
  final OneOfPlan oneOfPlan;

  final NameRegistry _registry;

  const ModelLayout._(
    this._fileBySpecName,
    this._membersByFile,
    this._wrappersByFile,
    this._unionsBySpecName,
    this._wrapperSpecByClassName,
    this.oneOfPlan,
    this._registry,
  );

  /// Builds the layout for [document].
  ///
  /// [oneOfPlan] must be the same instance passed to [buildNameRegistry]; when
  /// omitted it is rebuilt here from [document].
  factory ModelLayout.build(
    SpecDocument document,
    NameRegistry registry, {
    OneOfPlan? oneOfPlan,
  }) {
    final plan = oneOfPlan ?? OneOfPlan.build(document);

    String fileNameFor(String specName) =>
        '${toSnakeCase(registry.dartClassName(specName))}.dart';

    // --- Union-find over spec names ---
    final parent = <String, String>{
      for (final name in document.schemas.keys) name: name,
    };

    String find(String x) {
      var root = x;
      while (parent[root] != root) {
        root = parent[root]!;
      }
      // Path compression.
      var cur = x;
      while (parent[cur] != root) {
        final next = parent[cur]!;
        parent[cur] = root;
        cur = next;
      }
      return root;
    }

    void union(String a, String b) {
      final ra = find(a);
      final rb = find(b);
      if (ra == rb) return;
      // Keep the alphabetically smaller root so the result never depends on
      // iteration order.
      if (ra.compareTo(rb) <= 0) {
        parent[rb] = ra;
      } else {
        parent[ra] = rb;
      }
    }

    final wrapperNames = <String>{};
    final unionsBySpecName = <String, List<String>>{};
    final wrapperSpecByClassName = <String, String>{};

    for (final wrapper in plan.wrapperSpecNames) {
      wrapperNames.add(wrapper);
      wrapperSpecByClassName[registry.dartClassName(wrapper)] = wrapper;
      for (final branch in plan.branchesOf(wrapper)) {
        if (branch is! ReusedRefBranch) continue;
        if (branch.specName == wrapper) continue;
        union(wrapper, branch.specName);
        (unionsBySpecName[branch.specName] ??= <String>[]).add(
          registry.dartClassName(wrapper),
        );
      }
    }
    for (final implemented in unionsBySpecName.values) {
      implemented.sort();
    }

    // --- Group by root ---
    final groups = <String, List<String>>{};
    for (final name in document.schemas.keys) {
      groups.putIfAbsent(find(name), () => <String>[]).add(name);
    }

    final fileBySpecName = <String, String>{};
    final membersByFile = <String, List<String>>{};
    final wrappersByFile = <String, List<String>>{};

    for (final members in groups.values) {
      final wrappers = (members.where(wrapperNames.contains).toList())..sort();
      final others =
          (members.where((m) => !wrapperNames.contains(m)).toList())..sort();
      // Single-schema group: unchanged behaviour, file named after the schema.
      // Cluster: named after the alphabetically first wrapper. Class names are
      // globally unique (NameRegistry enforces it), so the file name is too.
      final fileName = fileNameFor(
        wrappers.isEmpty ? members.single : wrappers.first,
      );
      final ordered = [...wrappers, ...others];
      membersByFile[fileName] = ordered;
      wrappersByFile[fileName] = wrappers;
      for (final member in ordered) {
        fileBySpecName[member] = fileName;
      }
    }

    return ModelLayout._(
      fileBySpecName,
      membersByFile,
      wrappersByFile,
      unionsBySpecName,
      wrapperSpecByClassName,
      plan,
      registry,
    );
  }

  /// File declaring [specName], or `null` when the layout does not know the
  /// schema — which only happens for a name that is not a [SpecDocument]
  /// schema key.
  ///
  /// Prefer [resolveFile] unless the caller genuinely needs to distinguish
  /// "not in the layout" from "has a file".
  String? fileOf(String specName) => _fileBySpecName[specName];

  /// File declaring [specName], relative to `models/` — e.g. `'customer.dart'`.
  ///
  /// Total for every spec name the [NameRegistry] knows: a schema the layout
  /// itself does not track falls back to the file name its own Dart class name
  /// implies. Applying that fallback in one place is what keeps the model and
  /// the service generator importing the same file.
  ///
  /// Throws [StateError] (from [NameRegistry.dartClassName]) for a name that is
  /// not registered at all — there is no file to name in that case, and callers
  /// must not invent one.
  String resolveFile(String specName) =>
      fileOf(specName) ??
      '${toSnakeCase(_registry.dartClassName(specName))}.dart';

  /// File declaring [specName], relative to `models/` — e.g. `'customer.dart'`.
  ///
  /// Thin alias of [resolveFile], kept for existing callers, with the same
  /// contract: total for registered spec names, [StateError] for unregistered
  /// ones. Never returns an empty string — a caller that treated the result as
  /// "no import" would emit a file referencing a type it does not import.
  String fileFor(String specName) => resolveFile(specName);

  /// All file names, sorted.
  List<String> get files => _membersByFile.keys.toList()..sort();

  /// Spec names declared in [file]: `oneOf` wrappers first, then members.
  List<String> membersOf(String file) => _membersByFile[file] ?? const [];

  /// `oneOf` wrapper spec names declared in [file].
  List<String> wrappersOf(String file) => _wrappersByFile[file] ?? const [];

  /// Dart class names of the `oneOf` wrappers that have [specName] as a reused
  /// `$ref` branch — the `implements` clause of that class, sorted.
  ///
  /// Read straight off the union-find input: a reused branch always shares its
  /// wrapper's file, so no rescan of the emitted files is needed.
  List<String> unionsImplementedBy(String specName) =>
      _unionsBySpecName[specName] ?? const [];

  /// Whether [file] holds a `oneOf` wrapper plus its `$ref` branches.
  bool isCluster(String file) => membersOf(file).length > 1;

  /// Whether [dartClassName] is a `oneOf` wrapper with a branch that is not a
  /// JSON object — such a union decodes from a raw payload, so its `toJson`
  /// and `fromJson` are typed `Object?` and the service call site does not
  /// type the Dio response.
  ///
  /// Keyed by Dart class name, not by spec name: the service generator only
  /// ever holds the rendered return type of an operation. The lookup resolves
  /// that back to the spec name and defers to [OneOfPlan.isPolymorphic], so
  /// there is still only one source of truth.
  bool isPolymorphicUnion(String dartClassName) {
    final specName = _wrapperSpecByClassName[dartClassName];
    return specName != null && oneOfPlan.isPolymorphic(specName);
  }
}
