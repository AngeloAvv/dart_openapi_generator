import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';
import 'package:source_gen_test/source_gen_test.dart';
import 'package:test/test.dart';

import '../helpers/generator_factory.dart';

Future<void> main() async {
  initializeBuildLogTracking();
  final generator = createTestGenerator();

  final localSpecReader = await initializeLibraryReaderForDirectory(
    'test/golden/src',
    'local_spec_test_src.dart',
  );

  final remoteSpecHeadersReader = await initializeLibraryReaderForDirectory(
    'test/golden/src',
    'remote_spec_headers_test_src.dart',
  );

  final remoteSpecNoHeadersReader = await initializeLibraryReaderForDirectory(
    'test/golden/src',
    'remote_spec_no_headers_test_src.dart',
  );

  final functionAnnotationReader = await initializeLibraryReaderForDirectory(
    'test/golden/src',
    'function_annotation_test_src.dart',
  );

  final emptyOutputDirReader = await initializeLibraryReaderForDirectory(
    'test/golden/src',
    'empty_output_dir_test_src.dart',
  );

  group('LocalSpec', () {
    testAnnotatedElements<OpenApiGenerator>(localSpecReader, generator);
  });

  group('RemoteSpec with headers', () {
    testAnnotatedElements<OpenApiGenerator>(remoteSpecHeadersReader, generator);
  });

  group('RemoteSpec without headers', () {
    testAnnotatedElements<OpenApiGenerator>(
      remoteSpecNoHeadersReader,
      generator,
    );
  });

  group('function annotation (no @Target restriction)', () {
    testAnnotatedElements<OpenApiGenerator>(
      functionAnnotationReader,
      generator,
    );
  });

  group('empty outputDir (actionable error)', () {
    testAnnotatedElements<OpenApiGenerator>(emptyOutputDirReader, generator);
  });
}
