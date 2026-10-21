// Driver of test/e2e/form_bodies_e2e_test.dart. Not analyzed in place: the
// test copies it next to the code generated from the form fixtures, then runs
// it in its own isolate. It calls the generated clients through a Dio whose
// adapter records every request as it goes on the wire, and sends the
// recording back to the test.
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'files/generated.dart' as files;
import 'form/generated.dart' as form;
import 'multipart/generated.dart' as multipart;

/// Records each request and answers it: 401 for the next [unauthorized]
/// requests, a canned JSON body otherwise.
class _RecordingAdapter implements HttpClientAdapter {
  final requests = <Map<String, Object?>>[];
  var unauthorized = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = BytesBuilder();
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        body.add(chunk);
      }
    }
    requests.add({
      'method': options.method,
      'path': options.uri.path,
      'contentType': options.headers[Headers.contentTypeHeader],
      'body': body.takeBytes(),
    });
    if (unauthorized > 0) {
      unauthorized--;
      return ResponseBody.fromString('', 401);
    }
    return ResponseBody.fromString(
      jsonEncode(_answers[options.uri.path] ?? {}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _answers = {
  '/sessions': {'token': 't0k3n'},
  '/documents': {'id': 'doc-1'},
  '/tickets': {'id': 7},
};

Future<void> main(List<String> args, SendPort port) async {
  final adapter = _RecordingAdapter();
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
    ..httpClientAdapter = adapter;
  // The retry recipe the generated dartdoc prescribes: a token refresh sends
  // a copy of the FormData, never the one already sent.
  dio.interceptors.add(
    InterceptorsWrapper(
      onError: (error, handler) {
        if (error.response?.statusCode != 401) return handler.next(error);
        final options = error.requestOptions;
        if (options.data case final FormData data) {
          options.data = data.clone();
        }
        dio
            .fetch<dynamic>(options)
            .then(
              handler.resolve,
              onError: (Object e) => handler.reject(e as DioException),
            );
      },
    ),
  );

  // application/x-www-form-urlencoded
  final forms = form.ApiClient(dio: dio).forms;
  final session = await forms.signIn(
    form.SignInBody(
      email: 'ada@example.com',
      password: r's3cret&=',
      remember: true,
    ),
  );
  await forms.updateProfile(
    form.ProfileForm(
      name: 'Ada Lovelace',
      age: 36,
      admin: false,
      born: DateTime.utc(1815, 12, 10),
      role: form.Role.admin,
      tags: ['math', 'poetry'],
      ids: [1, 2, 3],
      labels: ['a', 'b'],
      address: form.Address(city: 'London'),
    ),
  );
  await forms.sendFeedback();

  // multipart/form-data, text and JSON parts
  final ticket = await multipart.ApiClient(dio: dio).tickets.createTicket(
    multipart.TicketForm(
      title: 'Printer on fire',
      priority: multipart.Priority.enum2,
      status: multipart.Status.open,
      dueAt: DateTime.utc(2026, 10, 21, 9, 30),
      urgent: true,
      labels: ['hw', 'urgent'],
      csv: 'a,b\n1,2',
      metadata: multipart.Metadata(source: 'web'),
      related: [multipart.Metadata(source: 'mail')],
    ),
  );

  // multipart/form-data with files: the same body sent twice
  final documents = files.ApiClient(dio: dio).documents;
  final upload = files.DocumentUpload(
    file: MultipartFile.fromBytes(
      utf8.encode('%PDF-1.4 fake'),
      filename: 'report.pdf',
      contentType: DioMediaType('application', 'pdf'),
    ),
    title: 'Q3 report',
    pages: 12,
  );
  final document = await documents.uploadDocument(upload);
  await documents.uploadDocument(upload);

  // A rejected multipart request, sent again by the interceptor
  adapter.unauthorized = 1;
  await documents.replaceAttachments(
    'doc-1',
    files.AttachmentsUpload(
      owner: 'ada',
      files: [
        MultipartFile.fromBytes([1, 2, 3], filename: 'a.bin'),
        MultipartFile.fromBytes([4, 5], filename: 'b.bin'),
      ],
    ),
  );

  port.send({
    'requests': adapter.requests,
    'results': {
      'session': session.token,
      'ticket': ticket.id,
      'document': document.id,
    },
  });
}
