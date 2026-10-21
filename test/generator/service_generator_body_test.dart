import 'package:dart_openapi_generator/src/date_time_converter.dart';
import 'package:dart_openapi_generator/src/generator/service_generator.dart';
import 'package:dart_openapi_generator/src/layout/model_layout.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/model/spec_document.dart';
import 'package:dart_openapi_generator/src/name_registry/name_registry.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

SpecDocument _doc(
  List<OperationItem> operations, {
  Map<String, SchemaObject> schemas = const {},
}) => SpecDocument(
  specVersion: '3.0.3',
  title: 'Test',
  baseUrl: 'https://api.example.com',
  schemas: schemas,
  operations: operations,
  securitySchemes: const {},
);

String _source(
  SpecDocument doc, {
  List<String>? warnings,
  DateTimeConverter dateTimeConverter = DateTimeConverter.iso8601,
}) {
  final registry = buildNameRegistry(doc);
  final result = ServiceGenerator(
    registry,
    ModelLayout.build(doc, registry),
    onWarning: warnings?.add,
    dateTimeConverter: dateTimeConverter,
  ).generate(doc);
  return result['services/things_api.dart']!;
}

OperationItem _post({
  RequestBodyObject? requestBody,
  Map<String, ResponseObject> responses = const {
    '204': ResponseObject(statusCode: '204', mediaType: null),
  },
  List<ParameterObject> parameters = const [],
  String method = 'post',
}) => OperationItem(
  path: '/things',
  method: method,
  operationId: 'sendThing',
  tags: const ['things'],
  parameters: parameters,
  requestBody: requestBody,
  responses: responses,
  security: const [],
  additionalMethods: const [],
);

const _str = PrimitiveSchema(primitiveType: 'string');

/// [source] with the line breaks dart_style inserts undone, so that an
/// expression can be matched whatever its length.
String _flat(String source) => source
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll('( ', '(')
    .replaceAll(' )', ')');

/// A `Thing` component with the given properties, all required unless listed
/// in [optional].
ObjectSchema _thing(
  Map<String, SchemaObject> properties, {
  Set<String> optional = const {},
}) => ObjectSchema(
  name: 'Thing',
  properties: [
    for (final MapEntry(:key, :value) in properties.entries)
      SchemaProperty(
        specName: key,
        schema: value,
        isRequired: !optional.contains(key),
      ),
  ],
  required: [
    for (final key in properties.keys)
      if (!optional.contains(key)) key,
  ],
);

String _formSource(
  String mediaType,
  ObjectSchema thing, {
  bool required = true,
  Map<String, EncodingObject> encoding = const {},
  Map<String, SchemaObject> extraSchemas = const {},
  List<String>? warnings,
  DateTimeConverter dateTimeConverter = DateTimeConverter.iso8601,
}) => _source(
  _doc(
    [
      _post(
        requestBody: RequestBodyObject(
          required: required,
          mediaType: mediaType,
          schema: thing,
          encoding: encoding,
        ),
      ),
    ],
    schemas: {'Thing': thing, ...extraSchemas},
  ),
  warnings: warnings,
  dateTimeConverter: dateTimeConverter,
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ServiceGenerator — application/x-www-form-urlencoded body', () {
    const urlEncoded = 'application/x-www-form-urlencoded';

    test(
      'typed with its model, sent as toJson() with the form content type',
      () {
        final src = _formSource(urlEncoded, _thing({'email': _str}));
        expect(src, contains('Thing body,'));
        expect(src, contains('data: body.toJson(),'));
        expect(
          src,
          contains('contentType: Headers.formUrlEncodedContentType,'),
        );
        expect(
          src,
          contains('[body] is sent as `application/x-www-form-urlencoded`.'),
        );
        expect(src, contains("import '../models/thing.dart';"));
      },
    );

    test('an optional body is a named nullable parameter', () {
      final src = _formSource(
        urlEncoded,
        _thing({'email': _str}),
        required: false,
      );
      expect(src, contains('Thing? body,'));
      expect(src, contains('data: body?.toJson(),'));
    });

    test('explode: false and the delimited styles switch the ListFormat', () {
      final src = _formSource(
        urlEncoded,
        _thing({
          'tags': const ArraySchema(items: _str),
          'ids': const ArraySchema(items: _str),
          'words': const ArraySchema(items: _str),
          'plain': const ArraySchema(items: _str),
        }),
        encoding: const {
          'tags': EncodingObject(explode: false),
          'ids': EncodingObject(style: 'pipeDelimited'),
          'words': EncodingObject(style: 'spaceDelimited'),
        },
      );
      expect(src, contains('final formFields = body.toJson();'));
      expect(
        src,
        contains("formFields['tags'] = ListParam(value, ListFormat.csv);"),
      );
      expect(
        src,
        contains("formFields['ids'] = ListParam(value, ListFormat.pipes);"),
      );
      expect(
        src,
        contains("formFields['words'] = ListParam(value, ListFormat.ssv);"),
      );
      // The default (form, explode: true) is Dio's own ListFormat.multi.
      expect(src, isNot(contains("formFields['plain']")));
      expect(src, contains('data: formFields,'));
    });

    test('an object property warns unless its style is deepObject', () {
      const address = ObjectSchema(
        name: 'Address',
        properties: [],
        required: [],
      );
      final warnings = <String>[];
      _formSource(
        urlEncoded,
        _thing({'home': address, 'work': address}),
        encoding: const {'work': EncodingObject(style: 'deepObject')},
        extraSchemas: const {'Address': address},
        warnings: warnings,
      );
      expect(warnings.where((w) => w.contains('is an object')), [
        allOf(
          contains('Operation "sendThing"'),
          contains('form property "home"'),
          contains('deepObject'),
        ),
      ]);
    });

    test('allowReserved and a part content type are warned about', () {
      final warnings = <String>[];
      _formSource(
        urlEncoded,
        _thing({'q': _str}),
        encoding: const {
          'q': EncodingObject(allowReserved: true, contentType: 'text/plain'),
        },
        warnings: warnings,
      );
      expect(warnings, contains(contains('"allowReserved: true"')));
      expect(warnings, contains(contains('content type "text/plain"')));
    });
  });

  group('ServiceGenerator — multipart/form-data body', () {
    const multipart = 'multipart/form-data';

    test('a new FormData is built in the method, one field per property', () {
      final src = _formSource(multipart, _thing({'url': _str}));
      expect(src, contains('Thing body,'));
      expect(src, contains('final formData = FormData();'));
      expect(src, contains("formData.fields.add(MapEntry('url', body.url));"));
      expect(src, contains('data: formData,'));
      // Dio sets the multipart Content-Type, boundary included.
      expect(src, isNot(contains('contentType:')));
    });

    test('the dartdoc tells interceptors to clone the FormData', () {
      final src = _formSource(multipart, _thing({'url': _str}));
      expect(src, contains('encoded into a new'));
      expect(src, contains('`(options.data as FormData).clone()`'));
    });

    test('an optional property is only added when non-null', () {
      final src = _formSource(
        multipart,
        _thing({'note': _str}, optional: {'note'}),
      );
      expect(src, contains('if (body.note != null) {'));
      expect(src, contains("MapEntry('note', body.note!)"));
    });

    test('scalars are sent as text', () {
      const role = EnumSchema(
        name: 'Role',
        enumType: 'string',
        values: ['admin'],
      );
      const level = EnumSchema(name: 'Level', enumType: 'integer', values: [1]);
      final src = _formSource(
        multipart,
        _thing({
          'count': const PrimitiveSchema(primitiveType: 'integer'),
          'ratio': const PrimitiveSchema(primitiveType: 'number'),
          'active': const PrimitiveSchema(primitiveType: 'boolean'),
          'at': const PrimitiveSchema(
            primitiveType: 'string',
            format: 'date-time',
          ),
          'role': role,
          'level': level,
        }),
        extraSchemas: const {'Role': role, 'Level': level},
      );
      expect(src, contains("MapEntry('count', body.count.toString())"));
      expect(src, contains("MapEntry('ratio', body.ratio.toString())"));
      expect(src, contains("MapEntry('active', body.active.toString())"));
      expect(src, contains("MapEntry('at', body.at.toIso8601String())"));
      expect(src, contains("MapEntry('role', body.role.toJson())"));
      expect(
        src,
        contains("MapEntry('level', body.level.toJson().toString())"),
      );
    });

    test('a date-time follows the date_time_converter', () {
      final src = _formSource(
        multipart,
        _thing({
          'at': const PrimitiveSchema(
            primitiveType: 'string',
            format: 'date-time',
          ),
        }),
        dateTimeConverter: DateTimeConverter.timestamp,
      );
      expect(
        src,
        contains("MapEntry('at', body.at.millisecondsSinceEpoch.toString())"),
      );
    });

    test('a binary property is a file part, cloned from the caller', () {
      final src = _formSource(
        multipart,
        _thing({
          'file': const PrimitiveSchema(
            primitiveType: 'string',
            format: 'binary',
          ),
          'pages': const ArraySchema(
            items: PrimitiveSchema(primitiveType: 'string', format: 'binary'),
          ),
        }),
      );
      expect(
        src,
        contains("formData.files.add(MapEntry('file', body.file.clone()));"),
      );
      expect(src, contains('for (final item in body.pages) {'));
      expect(
        src,
        contains("formData.files.add(MapEntry('pages', item.clone()));"),
      );
    });

    test('an array of scalars is one field per item', () {
      final src = _formSource(
        multipart,
        _thing({'tags': const ArraySchema(items: _str)}),
      );
      expect(src, contains('for (final item in body.tags) {'));
      expect(src, contains("formData.fields.add(MapEntry('tags', item));"));
    });

    test('an object property is an application/json part', () {
      const meta = ObjectSchema(name: 'Meta', properties: [], required: []);
      final src = _formSource(
        multipart,
        _thing({'meta': meta}),
        extraSchemas: const {'Meta': meta},
      );
      expect(src, contains("import 'dart:convert';"));
      expect(
        _flat(src),
        contains(
          'MultipartFile.fromString(jsonEncode(body.meta.toJson()), '
          "contentType: DioMediaType('application', 'json'))",
        ),
      );
    });

    test('encoding.contentType makes a scalar a typed part', () {
      final src = _formSource(
        multipart,
        _thing({'csv': _str}),
        encoding: const {'csv': EncodingObject(contentType: 'text/csv')},
      );
      expect(
        _flat(src),
        contains(
          "MultipartFile.fromString(body.csv, contentType: DioMediaType.parse('text/csv'))",
        ),
      );
    });

    test('a list of content types sends the first concrete one', () {
      const meta = ObjectSchema(name: 'Meta', properties: [], required: []);
      final warnings = <String>[];
      final src = _formSource(
        multipart,
        _thing({'csv': _str, 'meta': meta}),
        encoding: const {
          'csv': EncodingObject(contentType: 'text/*, text/csv, text/plain'),
          'meta': EncodingObject(
            contentType: 'application/json, application/vnd.x+json',
          ),
        },
        extraSchemas: const {'Meta': meta},
        warnings: warnings,
      );
      // A list, or a range, would make DioMediaType.parse throw at runtime.
      expect(_flat(src), contains("DioMediaType.parse('text/csv')"));
      expect(_flat(src), contains("DioMediaType.parse('application/json')"));
      expect(src, isNot(contains(', text/plain')));
      expect(
        warnings,
        contains(
          allOf(
            contains('multipart property "csv"'),
            contains('the part is sent as "text/csv"'),
          ),
        ),
      );
      expect(
        warnings,
        contains(contains('the part is sent as "application/json"')),
      );
    });

    test('a content type without a concrete media type is the default', () {
      final warnings = <String>[];
      final src = _formSource(
        multipart,
        _thing({'note': _str}),
        encoding: const {'note': EncodingObject(contentType: 'text/*')},
        warnings: warnings,
      );
      expect(
        src,
        contains("formData.fields.add(MapEntry('note', body.note));"),
      );
      expect(src, isNot(contains('DioMediaType')));
      expect(
        warnings,
        contains(contains('"text/*", which has no concrete media type')),
      );
    });

    test('encoding.contentType of a file is documented', () {
      final src = _formSource(
        multipart,
        _thing({
          'file': const PrimitiveSchema(
            primitiveType: 'string',
            format: 'binary',
          ),
        }),
        encoding: const {'file': EncodingObject(contentType: 'image/png')},
      );
      expect(src, contains('The spec expects the `file` file as `image/png`'));
    });

    test('an optional body builds the FormData only when given', () {
      final src = _formSource(
        multipart,
        _thing({'url': _str}),
        required: false,
      );
      expect(src, contains('Thing? body,'));
      expect(src, contains('if (body != null) {'));
      expect(src, contains('data: body == null ? null : formData,'));
    });

    test('a GET body is not encoded, since it is never sent', () {
      const meta = ObjectSchema(name: 'Meta', properties: [], required: []);
      final thing = _thing({'meta': meta});
      final src = _source(
        _doc(
          [
            _post(
              method: 'get',
              requestBody: RequestBodyObject(
                required: true,
                mediaType: multipart,
                schema: thing,
              ),
            ),
          ],
          schemas: {'Thing': thing, 'Meta': meta},
        ),
      );
      expect(src, isNot(contains('FormData')));
      expect(src, isNot(contains("import 'dart:convert';")));
    });

    test('per-part headers are warned about', () {
      final warnings = <String>[];
      _formSource(
        multipart,
        _thing({'url': _str}),
        encoding: const {'url': EncodingObject(hasHeaders: true)},
        warnings: warnings,
      );
      expect(warnings, contains(contains('per-part headers')));
    });

    test('a wire name with \$ is escaped', () {
      final src = _formSource(multipart, _thing({r'$type': _str}));
      expect(src, contains(r"MapEntry('\$type', body.$type)"));
    });
  });

  group('ServiceGenerator — untyped request body', () {
    OperationItem untyped(String mediaType, {bool required = true}) => _post(
      requestBody: RequestBodyObject(required: required, mediaType: mediaType),
    );

    test('an octet-stream upload is an Object body with its content type', () {
      final warnings = <String>[];
      final src = _source(
        _doc([untyped('application/octet-stream')]),
        warnings: warnings,
      );
      expect(src, contains('Object body,'));
      expect(src, contains("String contentType = 'application/octet-stream',"));
      expect(src, contains('data: body,'));
      expect(src, contains('contentType: contentType,'));
      expect(
        warnings,
        contains(
          allOf(
            contains('Operation "sendThing"'),
            contains('"application/octet-stream" is not typed'),
          ),
        ),
      );
    });

    test('an optional untyped body is Object?', () {
      final src = _source(_doc([untyped('text/plain', required: false)]));
      expect(src, contains('Object? body,'));
    });

    test('a media type range makes contentType required', () {
      final src = _source(_doc([untyped('image/*')]));
      expect(src, contains('required String contentType,'));
    });

    test('contentType yields to a parameter of the same name', () {
      final src = _source(
        _doc([
          _post(
            requestBody: const RequestBodyObject(
              required: true,
              mediaType: 'text/plain',
            ),
            parameters: const [
              ParameterObject(
                name: 'contentType',
                location: 'query',
                required: false,
                schema: _str,
              ),
            ],
          ),
        ]),
      );
      expect(src, contains("String bodyContentType = 'text/plain',"));
      expect(src, contains('contentType: bodyContentType,'));
    });

    test('a form body whose schema is not an object falls back to Object', () {
      final warnings = <String>[];
      final src = _source(
        _doc([
          _post(
            requestBody: const RequestBodyObject(
              required: true,
              mediaType: 'application/x-www-form-urlencoded',
              schema: ArraySchema(items: _str),
            ),
          ),
        ]),
        warnings: warnings,
      );
      expect(src, contains('Object body,'));
      expect(warnings, contains(contains('schema is not an object')));
    });
  });

  group('ServiceGenerator — JSON media types', () {
    final thing = _thing({'name': _str});

    String jsonSource(String mediaType) => _source(
      _doc(
        [
          _post(
            requestBody: RequestBodyObject(
              required: true,
              mediaType: mediaType,
              schema: thing,
            ),
          ),
        ],
        schemas: {'Thing': thing},
      ),
    );

    test('application/json leaves the content type to Dio', () {
      final src = jsonSource('application/json');
      expect(src, contains('data: body.toJson(),'));
      expect(src, isNot(contains('contentType:')));
    });

    test('a JSON variant is sent with its own content type', () {
      final src = jsonSource('application/vnd.api+json');
      expect(src, contains('data: body.toJson(),'));
      expect(src, contains("contentType: 'application/vnd.api+json',"));
    });

    test('a JSON body without a schema warns and takes no body', () {
      final warnings = <String>[];
      final src = _source(
        _doc([
          _post(
            requestBody: const RequestBodyObject(
              required: true,
              mediaType: 'application/json',
            ),
          ),
        ]),
        warnings: warnings,
      );
      expect(src, isNot(contains('body')));
      expect(warnings, contains(contains('declares no schema')));
    });
  });

  group('ServiceGenerator — non-JSON responses', () {
    String responseSource(String mediaType, {List<String>? warnings}) =>
        _source(
          _doc([
            _post(
              method: 'get',
              responses: {
                '200': ResponseObject(statusCode: '200', mediaType: mediaType),
              },
            ),
          ]),
          warnings: warnings,
        );

    test('a text response is returned as a String', () {
      final warnings = <String>[];
      final src = responseSource('text/plain', warnings: warnings);
      expect(src, contains('Future<String> sendThing('));
      expect(src, contains('_dio.get<String>('));
      expect(src, contains('responseType: ResponseType.plain,'));
      expect(src, contains('return data;'));
      expect(src, contains('Returns the `text/plain` response body as text.'));
      expect(warnings, contains(contains('sendThing (text/plain → String)')));
    });

    test('a binary response is returned as a Uint8List', () {
      final src = responseSource('application/octet-stream');
      expect(src, contains("import 'dart:typed_data';"));
      expect(src, contains('Future<Uint8List> sendThing('));
      expect(src, contains('_dio.get<Uint8List>('));
      expect(src, contains('responseType: ResponseType.bytes,'));
    });

    test('a JSON response without a schema warns and returns void', () {
      final warnings = <String>[];
      final src = responseSource('application/json', warnings: warnings);
      expect(src, contains('Future<void> sendThing('));
      expect(warnings, contains(contains('without a schema')));
    });
  });

  // -------------------------------------------------------------------------
  // Whole pipeline on the fixtures
  // -------------------------------------------------------------------------

  group('Fixture form_app.yaml (form bodies as components)', () {
    test('signIn takes SignInBody and sends it url-encoded', () async {
      final result = await generateFixture('form_app.yaml');
      final method = methodSource(
        result.files['services/auth_api.dart']!,
        'signIn',
      );
      expect(
        method,
        contains('Future<Session> signIn(\n    SignInBody body, {'),
      );
      expect(method, contains('data: body.toJson(),'));
      expect(
        method,
        contains('contentType: Headers.formUrlEncodedContentType,'),
      );
    });

    test('getPreview takes PreviewBody and sends it as multipart', () async {
      final result = await generateFixture('form_app.yaml');
      final method = methodSource(
        result.files['services/links_api.dart']!,
        'getPreview',
      );
      expect(
        method,
        contains('Future<Preview> getPreview(\n    PreviewBody body, {'),
      );
      expect(method, contains('final formData = FormData();'));
      expect(
        method,
        contains("formData.fields.add(MapEntry('url', body.url));"),
      );
      expect(method, contains('data: formData,'));
    });

    test('every form body is typed: no request body warning', () async {
      final result = await generateFixture('form_app.yaml');
      expect(result.warnings, everyElement(isNot(contains('request body'))));
      for (final (file, method, type) in [
        ('auth_api.dart', 'signUp', 'SignUpBody'),
        ('auth_api.dart', 'resetPassword', 'ResetPasswordBody'),
        ('bookmarks_api.dart', 'createBookmark', 'BookmarkBody'),
      ]) {
        final src = methodSource(result.files['services/$file']!, method);
        expect(src, contains('$type body'), reason: method);
        expect(
          src,
          contains('Headers.formUrlEncodedContentType'),
          reason: method,
        );
      }
    });
  });

  group('Fixture form_app_inline.yaml (inline form bodies)', () {
    test('inline form schemas get <Operation>Request models', () async {
      final result = await generateFixture('form_app_inline.yaml');
      expect(
        result.files['services/auth_api.dart'],
        contains('Future<Session> postLogin(\n    PostLoginRequest body, {'),
      );
      expect(
        result.files['services/links_api.dart'],
        contains(
          'Future<Preview> postPreview(\n    PostPreviewRequest body, {',
        ),
      );
      expect(result.files.keys, contains('models/post_login_request.dart'));
      expect(result.files.keys, contains('models/post_preview_request.dart'));
    });
  });

  group('Fixture mixed_media_types.yaml', () {
    late Map<String, String> files;
    late List<String> warnings;
    late String pets;

    setUpAll(() async {
      final result = await generateFixture('mixed_media_types.yaml');
      files = result.files;
      warnings = result.warnings;
      pets = files['services/pets_api.dart']!;
    });

    test('JSON wins over XML and url-encoded, in body and response', () {
      final method = methodSource(pets, 'createPet');
      expect(method, contains('Future<Pet> createPet(\n    Pet body, {'));
      expect(method, contains('data: body.toJson(),'));
      expect(method, isNot(contains('contentType')));
    });

    test('url-encoded wins over multipart', () {
      final method = methodSource(pets, 'updatePetForm');
      expect(method, contains('Headers.formUrlEncodedContentType'));
      expect(method, isNot(contains('FormData')));
    });

    test('merge-patch+json and a charset parameter are JSON', () {
      final method = methodSource(pets, 'patchPet');
      expect(method, contains('Future<Pet> patchPet('));
      expect(method, contains("contentType: 'application/merge-patch+json',"));
    });

    test('an image upload takes the content type from the caller', () {
      final method = methodSource(pets, 'uploadPhoto');
      expect(method, contains('Object body, {'));
      expect(method, contains('required String contentType,'));
    });

    test('an image download returns bytes, a CSV export text', () {
      expect(
        methodSource(pets, 'downloadPhoto'),
        contains('Future<Uint8List>'),
      );
      expect(methodSource(pets, 'exportPets'), contains('Future<String>'));
    });

    test('a text body and a text response', () {
      final method = methodSource(pets, 'putNotes');
      expect(method, contains('Future<String> putNotes('));
      expect(method, contains('Object? body,'));
      expect(method, contains("String contentType = 'text/plain',"));
    });

    test('a problem+json error schema generates its model', () {
      expect(files.keys, contains('models/problem.dart'));
    });

    test('every fallback is warned about, naming operation and media type', () {
      final all = warnings.join('\n');
      expect(
        all,
        allOf([
          contains(
            'Operation "importPets": the "application/x-www-form-urlencoded" request body schema is not an object',
          ),
          contains(
            'Operation "pingPets": the "application/json" request body declares no schema',
          ),
          contains(
            'Operation "pingPets": the 200 response is "application/json" without a schema',
          ),
          contains(
            'Operation "putNotes": the request body media type "text/plain" is not typed',
          ),
          contains(
            'Operation "uploadPhoto": the request body media type "image/*" is not typed',
          ),
          contains('downloadPhoto (image/png → Uint8List)'),
          contains('exportPets (text/csv → String)'),
        ]),
      );
    });
  });

  group('Fixture form_urlencoded.yaml', () {
    test('every unsupported serialization of saveFilters warns', () async {
      final result = await generateFixture('form_urlencoded.yaml');
      final filters = result.warnings.where(
        (w) => w.startsWith('Operation "saveFilters"'),
      );
      expect(filters, hasLength(4));
      // updateProfile only uses supported serializations.
      expect(
        result.warnings,
        everyElement(isNot(startsWith('Operation "updateProfile"'))),
      );
    });

    test('a free-form body sends its map', () async {
      final result = await generateFixture('form_urlencoded.yaml');
      final method = methodSource(
        result.files['services/forms_api.dart']!,
        'putSettings',
      );
      expect(method, contains('data: body?.additionalProperties,'));
    });
  });

  group('Fixture multipart.yaml', () {
    test('a free-form multipart body is FormData.fromMap', () async {
      final result = await generateFixture('multipart.yaml');
      final method = methodSource(
        result.files['services/tickets_api.dart']!,
        'importTickets',
      );
      expect(
        method,
        contains('data: FormData.fromMap(body.additionalProperties),'),
      );
    });

    test('a vendor JSON part keeps its declared content type', () async {
      final result = await generateFixture('multipart.yaml');
      final method = methodSource(
        result.files['services/tickets_api.dart']!,
        'createTicket',
      );
      expect(
        method,
        contains("DioMediaType.parse('application/vnd.ticket+json')"),
      );
    });
  });
}
