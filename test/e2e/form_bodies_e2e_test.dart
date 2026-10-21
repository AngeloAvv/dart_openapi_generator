import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// Runs the code generated from the form fixtures against a recording Dio
/// adapter (see `driver/forms_driver.dart`) and checks what goes on the wire:
/// the `Content-Type` and the exact bytes of every body.
void main() {
  late List<Map<String, Object?>> requests;
  late Map<String, Object?> results;

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('form_bodies_e2e');
    addTearDown(() => dir.delete(recursive: true));

    for (final (fixture, folder) in [
      ('form_urlencoded.yaml', 'form'),
      ('multipart.yaml', 'multipart'),
      ('multipart_files.yaml', 'files'),
    ]) {
      final generated = await generateFixture(fixture);
      for (final MapEntry(:key, :value) in generated.files.entries) {
        File(p.join(dir.path, folder, key))
          ..createSync(recursive: true)
          ..writeAsStringSync(value);
      }
    }
    final driver = p.join(p.dirname(await fixturePath('')), 'e2e', 'driver');
    final main = File(
      p.join(driver, 'forms_driver.dart'),
    ).copySync(p.join(dir.path, 'main.dart'));

    final port = ReceivePort();
    final errors = ReceivePort();
    await Isolate.spawnUri(
      main.uri,
      const [],
      port.sendPort,
      // Resolves `package:dio` with this package's configuration.
      packageConfig: await Isolate.packageConfig,
      onError: errors.sendPort,
    );
    final message = await Future.any([
      port.first,
      errors.first.then((error) => throw StateError('Driver failed: $error')),
    ]);
    port.close();
    errors.close();
    final recording = message as Map;
    requests = [
      for (final request in recording['requests'] as List)
        Map<String, Object?>.from(request as Map),
    ];
    results = Map<String, Object?>.from(recording['results'] as Map);
  });

  Map<String, Object?> request(String path, [int index = 0]) =>
      requests.where((r) => r['path'] == path).elementAt(index);
  String body(Map<String, Object?> request) =>
      utf8.decode(request['body'] as List<int>);

  group('application/x-www-form-urlencoded on the wire', () {
    test('a typed body is url-encoded, its response decoded', () {
      final signIn = request('/sessions');
      expect(signIn['method'], 'POST');
      expect(signIn['contentType'], 'application/x-www-form-urlencoded');
      expect(
        body(signIn),
        'email=ada%40example.com&password=s3cret%26%3D&remember=true',
      );
      expect(results['session'], 't0k3n');
    });

    test('scalars, dates, enums, lists and objects follow the encoding', () {
      final profile = request('/profile');
      expect(profile['contentType'], 'application/x-www-form-urlencoded');
      expect(
        body(profile).split('&'),
        [
          // style: deepObject
          'address%5Bcity%5D=London',
          'admin=false',
          'age=36',
          'born=1815-12-10T00%3A00%3A00.000Z',
          // explode: false
          'ids=1%2C2%2C3',
          // style: pipeDelimited
          'labels=a%7Cb',
          'name=Ada+Lovelace',
          'role=admin',
          // the default: style: form, explode: true
          'tags=math',
          'tags=poetry',
        ],
        // nickname (nullable) and score (optional) are null: omitted.
      );
    });

    test('an optional body left out sends no body', () {
      expect(request('/feedback')['body'], isEmpty);
    });
  });

  group('multipart/form-data on the wire', () {
    /// The parts of a multipart [request], checking its framing.
    List<String> parts(Map<String, Object?> request) {
      final contentType = request['contentType'] as String;
      expect(contentType, startsWith('multipart/form-data; boundary='));
      final boundary = contentType.split('boundary=').last;
      final text = body(request);
      expect(text, startsWith('--$boundary\r\n'));
      expect(text, endsWith('\r\n--$boundary--\r\n'));
      return text
          .substring(0, text.length - '\r\n--$boundary--\r\n'.length)
          .split(RegExp('(^|\r\n)--$boundary\r\n'))
          .skip(1)
          .toList();
    }

    String field(String name, String value) =>
        'content-disposition: form-data; name="$name"\r\n\r\n$value';
    String file(
      String name,
      String contentType,
      String content, {
      String? filename,
    }) =>
        'content-disposition: form-data; name="$name"'
        '${filename == null ? '' : '; filename="$filename"'}\r\n'
        'content-type: $contentType\r\n\r\n$content';

    test('text fields, then the typed and JSON parts', () {
      expect(parts(request('/tickets')), [
        field('title', 'Printer on fire'),
        field('priority', '2'),
        field('status', 'open'),
        field('dueAt', '2026-10-21T09:30:00.000Z'),
        field('urgent', 'true'),
        field('labels', 'hw'),
        field('labels', 'urgent'),
        // encoding.contentType: text/csv
        file('csv', 'text/csv; charset=utf-8', 'a,b\n1,2'),
        // encoding.contentType: application/vnd.ticket+json
        file(
          'metadata',
          'application/vnd.ticket+json; charset=utf-8',
          '{"source":"web"}',
        ),
        // an object without encoding: application/json
        file('related', 'application/json; charset=utf-8', '{"source":"mail"}'),
      ]);
      expect(results['ticket'], 7);
    });

    test('a file part carries its name, filename and content type', () {
      expect(parts(request('/documents')), [
        field('title', 'Q3 report'),
        field('pages', '12'),
        file(
          'file',
          'application/pdf',
          '%PDF-1.4 fake',
          filename: 'report.pdf',
        ),
      ]);
      expect(results['document'], 'doc-1');
    });

    test('the same body sent twice is encoded into a new FormData', () {
      final first = request('/documents');
      final second = request('/documents', 1);
      // A new FormData has a new boundary...
      expect(second['contentType'], isNot(first['contentType']));
      // ...and the same parts: the caller's file was cloned, not used up.
      expect(parts(second), parts(first));
    });

    test('a request sent again by an interceptor sends the same bytes', () {
      final attempts = requests.where(
        (r) => r['path'] == '/documents/doc-1/attachments',
      );
      expect(attempts, hasLength(2));
      final [rejected, retried] = attempts.toList();
      expect(retried['contentType'], rejected['contentType']);
      expect(retried['body'], rejected['body']);
      expect(parts(retried), [
        field('owner', 'ada'),
        file(
          'files',
          'application/octet-stream',
          '\x01\x02\x03',
          filename: 'a.bin',
        ),
        file(
          'files',
          'application/octet-stream',
          '\x04\x05',
          filename: 'b.bin',
        ),
      ]);
    });
  });
}
