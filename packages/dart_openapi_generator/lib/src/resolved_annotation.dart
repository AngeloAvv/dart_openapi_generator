import 'package:analyzer/dart/element/element.dart';
import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';
import 'package:source_gen/source_gen.dart';

/// Strongly-typed representation of a decoded [@OpenApiGenerator] annotation.
///
/// Produced by [ResolvedAnnotation.fromConstantReader] during build-time
/// annotation processing. All 8 annotation fields are decoded here; downstream
/// phases consume this object rather than a raw [ConstantReader].
final class ResolvedAnnotation {
  final InputSpec inputSpec;
  final String outputDir;
  final String clientName;
  final bool skipIfSpecIsUnchanged;
  final String cachePath;
  final bool cleanOutput;
  final DateTimeConverter dateTimeConverter;
  final bool debugLogging;

  const ResolvedAnnotation({
    required this.inputSpec,
    required this.outputDir,
    required this.clientName,
    required this.skipIfSpecIsUnchanged,
    required this.cachePath,
    required this.cleanOutput,
    required this.dateTimeConverter,
    required this.debugLogging,
  });

  // TypeCheckers use source-file URIs, NOT barrel re-export URIs.
  // Using the barrel URI causes annotatedWith() to return empty.
  static final _localSpecChecker = TypeChecker.fromUrl(
    'package:dart_openapi_generator_annotations/src/input_spec.dart#LocalSpec',
  );
  static final _remoteSpecChecker = TypeChecker.fromUrl(
    'package:dart_openapi_generator_annotations/src/input_spec.dart#RemoteSpec',
  );

  factory ResolvedAnnotation.fromConstantReader(
    ConstantReader annotation,
    Element element,
  ) {
    return ResolvedAnnotation(
      inputSpec: _readInputSpec(annotation, element),
      outputDir: annotation.read('outputDir').stringValue,
      clientName: annotation.read('clientName').stringValue,
      skipIfSpecIsUnchanged: annotation.read('skipIfSpecIsUnchanged').boolValue,
      cachePath: annotation.read('cachePath').stringValue,
      cleanOutput: annotation.read('cleanOutput').boolValue,
      dateTimeConverter: _readDateTimeConverter(annotation),
      debugLogging: annotation.read('debugLogging').boolValue,
    );
  }

  static InputSpec _readInputSpec(ConstantReader annotation, Element element) {
    final specReader = annotation.read('inputSpec');
    if (specReader.instanceOf(_localSpecChecker)) {
      return LocalSpec(specReader.read('path').stringValue);
    } else if (specReader.instanceOf(_remoteSpecChecker)) {
      final url = specReader.read('url').stringValue;
      final headersReader = specReader.peek('headers');
      Map<String, String>? headers;
      if (headersReader != null && !headersReader.isNull) {
        headers = {
          for (final entry in headersReader.mapValue.entries)
            entry.key!.toStringValue()!: entry.value!.toStringValue()!,
        };
      }
      return RemoteSpec(url, headers: headers);
    }
    // Sealed class invariant: only LocalSpec and RemoteSpec exist.
    // This branch is unreachable at runtime; defensive error for future proofing.
    throw InvalidGenerationSource(
      'Unknown InputSpec subtype: ${specReader.objectValue.type}. '
      'Expected LocalSpec or RemoteSpec.',
      element: element,
    );
  }

  static DateTimeConverter _readDateTimeConverter(ConstantReader annotation) {
    // Use revive().accessor to extract enum value name.
    // Do NOT use objectValue.getField('_name') — internal field, not stable.
    final revived = annotation.read('dateTimeConverter').revive();
    final raw = revived.accessor;
    final name = raw.split('.').last;
    if (name.isEmpty) {
      throw InvalidGenerationSource(
        'Could not resolve dateTimeConverter enum value '
        '(revive accessor was "$raw"). '
        'Ensure you pass a DateTimeConverter literal, e.g. '
        'dateTimeConverter: DateTimeConverter.iso8601',
      );
    }
    return DateTimeConverter.values.byName(name);
  }
}
