import 'dart:isolate';

import 'package:dart_openapi_generator/src/builder/open_api_builder.dart';
import 'package:dart_openapi_generator/src/date_time_converter.dart';
import 'package:dart_openapi_generator/src/generator_config.dart';
import 'package:dart_openapi_generator/src/model_class_modifier.dart';
import 'package:path/path.dart' as p;

/// Absolute path of `test/fixtures/<name>`.
Future<String> fixturePath(String name) async {
  final packageUri = await Isolate.resolvePackageUri(
    Uri.parse('package:dart_openapi_generator/'),
  );
  // packageUri points to lib/ inside the package root
  return p.normalize(
    p.join(packageUri!.toFilePath(), '..', 'test', 'fixtures', name),
  );
}

/// Runs the whole pipeline — the one the builder runs — on the fixture
/// [name]: generated files keyed by path relative to `output_dir`, and the
/// build warnings.
Future<({Map<String, String> files, List<String> warnings})> generateFixture(
  String name, {
  String clientName = 'ApiClient',
  DateTimeConverter dateTimeConverter = DateTimeConverter.iso8601,
}) async => OpenApiBuilder.generateFiles(
  GeneratorConfig(
    inputSpec: await fixturePath(name),
    outputDir: 'lib/generated',
    clientName: clientName,
    dateTimeConverter: dateTimeConverter,
    modelClassModifier: ModelClassModifier.final$,
    debugLogging: false,
  ),
);

/// The source of the method [name] in [source]: from its dartdoc to its
/// closing brace.
String methodSource(String source, String name) {
  final lines = source.split('\n');
  final signature = lines.indexWhere(
    (line) => RegExp('^  [^ ].* $name[(<]').hasMatch(line),
  );
  if (signature < 0) throw StateError('Method $name not found');
  var start = signature;
  while (start > 0 && lines[start - 1].startsWith('  ///')) {
    start--;
  }
  final end = lines.indexWhere((line) => line == '  }', signature);
  return lines.sublist(start, end + 1).join('\n');
}
