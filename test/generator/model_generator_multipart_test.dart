import 'package:dart_openapi_generator/src/date_time_converter.dart';
import 'package:dart_openapi_generator/src/generator/model_generator.dart';
import 'package:dart_openapi_generator/src/layout/model_layout.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/model/spec_document.dart';
import 'package:dart_openapi_generator/src/name_registry/name_registry.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

const _binary = PrimitiveSchema(primitiveType: 'string', format: 'binary');

const _upload = ObjectSchema(
  name: 'Upload',
  properties: [
    SchemaProperty(specName: 'file', schema: _binary, isRequired: true),
    SchemaProperty(
      specName: 'title',
      schema: PrimitiveSchema(primitiveType: 'string'),
      isRequired: false,
    ),
  ],
  required: ['file'],
);

/// The `Upload` model, sent as a body with [mediaType].
String _uploadModel(String mediaType) {
  final doc = SpecDocument(
    specVersion: '3.0.3',
    title: 'Test',
    baseUrl: '',
    schemas: const {'Upload': _upload},
    operations: [
      OperationItem(
        path: '/uploads',
        method: 'post',
        operationId: 'upload',
        tags: const [],
        parameters: const [],
        requestBody: RequestBodyObject(
          required: true,
          mediaType: mediaType,
          schema: _upload,
        ),
        responses: const {},
        security: const [],
        additionalMethods: const [],
      ),
    ],
    securitySchemes: const {},
  );
  final registry = buildNameRegistry(doc);
  return ModelGenerator(
    registry,
    ModelLayout.build(doc, registry),
    DateTimeConverter.iso8601,
  ).generate(doc)['models/upload.dart']!;
}

void main() {
  group('ModelGenerator — binary properties of a multipart body', () {
    test('a binary property is a MultipartFile, imported from Dio', () {
      final src = _uploadModel('multipart/form-data');
      expect(src, contains("import 'package:dio/dio.dart';"));
      expect(src, contains('final MultipartFile file;'));
      expect(src, contains("json['file'] as MultipartFile"));
      // toJson() hands the file over untouched.
      expect(src, contains("'file': file,"));
    });

    test('the same schema sent as JSON keeps a String', () {
      final src = _uploadModel('application/json');
      expect(src, isNot(contains('dio')));
      expect(src, contains('final String file;'));
    });

    test('the same schema sent url-encoded keeps a String', () {
      final src = _uploadModel('application/x-www-form-urlencoded');
      expect(src, contains('final String file;'));
    });
  });

  group('Fixture multipart_files.yaml', () {
    late Map<String, String> files;

    setUpAll(() async {
      files = (await generateFixture('multipart_files.yaml')).files;
    });

    test('DocumentUpload has required and optional files', () {
      final src = files['models/document_upload.dart']!;
      expect(src, contains('final MultipartFile file;'));
      expect(src, contains('final MultipartFile? thumbnail;'));
      expect(src, contains('final String title;'));
    });

    test('an allOf body merges an array of files', () {
      final src = files['models/attachments_upload.dart']!;
      expect(src, contains('final List<MultipartFile> files;'));
      expect(src, contains('.cast<MultipartFile>()'));
      expect(src, contains('final String owner;'));
    });

    test('a binary property of a JSON body stays a String', () {
      final src = files['models/raw_document.dart']!;
      expect(src, contains('final String content;'));
      expect(src, isNot(contains('MultipartFile')));
    });
  });

  group('Fixture multipart_files_31.yaml', () {
    test(
      'contentMediaType is a file, unless it has a contentEncoding',
      () async {
        final files = (await generateFixture('multipart_files_31.yaml')).files;
        final src = files['models/upload_avatar_request.dart']!;
        expect(src, contains('final MultipartFile image;'));
        expect(src, contains('final List<MultipartFile>? previews;'));
        expect(src, contains('final String? signature;'));
        expect(src, contains('final String? caption;'));
      },
    );
  });
}
