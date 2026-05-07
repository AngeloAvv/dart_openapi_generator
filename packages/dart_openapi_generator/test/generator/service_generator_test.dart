import 'package:dart_openapi_generator/src/generator/service_generator.dart';
import 'package:dart_openapi_generator/src/model/schema_object.dart';
import 'package:dart_openapi_generator/src/model/spec_document.dart';
import 'package:dart_openapi_generator/src/name_registry/name_registry.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

SpecDocument _makeDoc({List<OperationItem> operations = const []}) =>
    SpecDocument(
      specVersion: '3.0.3',
      title: 'Test',
      baseUrl: 'https://api.example.com',
      schemas: const {},
      operations: operations,
      securitySchemes: const {},
    );

/// Build a [SpecDocument] with both a schemas map and operations list.
/// Required when the NameRegistry must resolve named schema types.
SpecDocument _makeDocWithSchemas({
  Map<String, SchemaObject> schemas = const {},
  List<OperationItem> operations = const [],
}) => SpecDocument(
  specVersion: '3.0.3',
  title: 'Test',
  baseUrl: 'https://api.example.com',
  schemas: schemas,
  operations: operations,
  securitySchemes: const {},
);

ServiceGenerator _makeGen(SpecDocument doc, {List<String>? warnings}) =>
    ServiceGenerator(buildNameRegistry(doc), onWarning: warnings?.add);

String _source(SpecDocument doc, String filename, {List<String>? warnings}) {
  final result = _makeGen(doc, warnings: warnings).generate(doc);
  return result[filename] ??
      (throw StateError('File not found: $filename. Got: ${result.keys}'));
}

const _strSchema = PrimitiveSchema(primitiveType: 'string');
const _intSchema = PrimitiveSchema(primitiveType: 'integer');

const _ok200 = ResponseObject(
  statusCode: '200',
  jsonSchema: PrimitiveSchema(primitiveType: 'string'),
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // tag → file mapping, class structure
  // -------------------------------------------------------------------------
  group('ServiceGenerator — tag-to-file mapping and class structure', () {
    test('single tagged operation → services/user_api.dart in result map', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/users',
            method: 'get',
            operationId: 'listUsers',
            tags: ['user'],
            parameters: [],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final result = _makeGen(doc).generate(doc);
      expect(result.containsKey('services/user_api.dart'), isTrue);
    });

    test('file contains class UserApi', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/users',
            method: 'get',
            operationId: 'listUsers',
            tags: ['user'],
            parameters: [],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final src = _source(doc, 'services/user_api.dart');
      expect(src, contains('class UserApi'));
    });

    test('file contains const UserApi(this._dio) constructor', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/users',
            method: 'get',
            operationId: 'listUsers',
            tags: ['user'],
            parameters: [],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final src = _source(doc, 'services/user_api.dart');
      expect(src, contains('const UserApi(this._dio)'));
    });

    test('file contains final Dio _dio field', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/users',
            method: 'get',
            operationId: 'listUsers',
            tags: ['user'],
            parameters: [],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final src = _source(doc, 'services/user_api.dart');
      expect(src, contains('final Dio _dio'));
    });

    test(
      'untagged operation (tags: []) → services/default_api.dart, class DefaultApi',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/ping',
              method: 'get',
              operationId: 'ping',
              tags: [],
              parameters: [],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final result = _makeGen(doc).generate(doc);
        expect(result.containsKey('services/default_api.dart'), isTrue);
        final src = result['services/default_api.dart']!;
        expect(src, contains('class DefaultApi'));
      },
    );

    test('file starts with GENERATED CODE header', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/items',
            method: 'get',
            operationId: 'listItems',
            tags: ['item'],
            parameters: [],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final src = _source(doc, 'services/item_api.dart');
      expect(src, startsWith('// GENERATED CODE - DO NOT MODIFY BY HAND'));
    });
  });

  // -------------------------------------------------------------------------
  // method naming
  // -------------------------------------------------------------------------
  group('ServiceGenerator — method naming', () {
    test('operationId "getUser" → method name getUser', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/users/{id}',
            method: 'get',
            operationId: 'getUser',
            tags: ['user'],
            parameters: [
              ParameterObject(
                name: 'id',
                location: 'path',
                required: true,
                schema: _strSchema,
              ),
            ],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final src = _source(doc, 'services/user_api.dart');
      expect(src, contains('getUser('));
    });

    test('no operationId, method=get, path=/users → method name getUsers', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/users',
            method: 'get',
            tags: ['user'],
            parameters: [],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final src = _source(doc, 'services/user_api.dart');
      expect(src, contains('getUsers('));
    });

    test('reserved-word operationId "get" → method name get_', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/items/{id}',
            method: 'get',
            operationId: 'get',
            tags: ['item'],
            parameters: [
              ParameterObject(
                name: 'id',
                location: 'path',
                required: true,
                schema: _strSchema,
              ),
            ],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final src = _source(doc, 'services/item_api.dart');
      expect(src, contains('get_('));
    });
  });

  // -------------------------------------------------------------------------
  // HTTP verbs and 3.2 additionalMethods
  // -------------------------------------------------------------------------
  group('ServiceGenerator — HTTP verbs and additionalMethods', () {
    OperationItem makeOp(
      String method, {
      List<String> additionalMethods = const [],
    }) => OperationItem(
      path: '/resource',
      method: method,
      operationId: '${method}Resource',
      tags: ['resource'],
      parameters: const [],
      responses: const {'200': _ok200},
      security: const [],
      additionalMethods: additionalMethods,
    );

    test('method=get → source contains _dio.get<', () {
      final doc = _makeDoc(operations: [makeOp('get')]);
      final src = _source(doc, 'services/resource_api.dart');
      expect(src, contains('_dio.get<'));
    });

    test('method=post → source contains _dio.post<', () {
      final doc = _makeDoc(operations: [makeOp('post')]);
      final src = _source(doc, 'services/resource_api.dart');
      expect(src, contains('_dio.post<'));
    });

    test('method=put → source contains _dio.put<', () {
      final doc = _makeDoc(operations: [makeOp('put')]);
      final src = _source(doc, 'services/resource_api.dart');
      expect(src, contains('_dio.put<'));
    });

    test('method=patch → source contains _dio.patch<', () {
      final doc = _makeDoc(operations: [makeOp('patch')]);
      final src = _source(doc, 'services/resource_api.dart');
      expect(src, contains('_dio.patch<'));
    });

    test('method=delete → source contains _dio.delete<', () {
      final doc = _makeDoc(operations: [makeOp('delete')]);
      final src = _source(doc, 'services/resource_api.dart');
      expect(src, contains('_dio.delete<'));
    });

    test('method=head → source contains _dio.head<', () {
      final doc = _makeDoc(operations: [makeOp('head')]);
      final src = _source(doc, 'services/resource_api.dart');
      expect(src, contains('_dio.head<'));
    });

    test(
      'method=options → source contains _dio.request< and method: OPTIONS (Dio has no .options() method)',
      () {
        final doc = _makeDoc(operations: [makeOp('options')]);
        final src = _source(doc, 'services/resource_api.dart');
        // Dio exposes .options as a BaseOptions property, not a callable HTTP
        // method. OPTIONS requests must use _dio.request(method: 'OPTIONS', ...).
        expect(src, contains('_dio.request<'));
        expect(src, contains("method: 'OPTIONS'"));
        expect(src, isNot(contains('_dio.options<')));
      },
    );

    test('method=trace → source contains _dio.request< and method: TRACE', () {
      final doc = _makeDoc(operations: [makeOp('trace')]);
      final src = _source(doc, 'services/resource_api.dart');
      expect(src, contains('_dio.request<'));
      expect(src, contains("method: 'TRACE'"));
    });

    test(
      'additionalMethods: [QUERY] on GET op → source contains _dio.request< and method: QUERY',
      () {
        final warnings = <String>[];
        final doc = _makeDoc(
          operations: [
            makeOp('get', additionalMethods: ['QUERY']),
          ],
        );
        final src = _source(
          doc,
          'services/resource_api.dart',
          warnings: warnings,
        );
        expect(src, contains('_dio.request<'));
        expect(src, contains("method: 'QUERY'"));
      },
    );

    test(
      'two ops with same path both carrying additionalMethods: [QUERY] → stub appears exactly once',
      () {
        final warnings = <String>[];
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/resource',
              method: 'get',
              operationId: 'getResource',
              tags: ['resource'],
              parameters: [],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: ['QUERY'],
            ),
            const OperationItem(
              path: '/resource',
              method: 'post',
              operationId: 'postResource',
              tags: ['resource'],
              parameters: [],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: ['QUERY'],
            ),
          ],
        );
        final src = _source(
          doc,
          'services/resource_api.dart',
          warnings: warnings,
        );
        // Count occurrences of "method: 'QUERY'" — should be exactly 1
        final count = "method: 'QUERY'".allMatches(src).length;
        expect(
          count,
          equals(1),
          reason: 'QUERY stub should be deduplicated to exactly one occurrence',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // path parameter interpolation
  // -------------------------------------------------------------------------
  group('ServiceGenerator — path parameter interpolation', () {
    test(
      'path /users/{id}, one path param → source contains Uri.encodeComponent(id)',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/users/{id}',
              method: 'get',
              operationId: 'getUser',
              tags: ['user'],
              parameters: [
                ParameterObject(
                  name: 'id',
                  location: 'path',
                  required: true,
                  schema: _strSchema,
                ),
              ],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/user_api.dart');
        expect(src, contains('Uri.encodeComponent(id)'));
      },
    );

    test(
      'path /users/{userId}/posts/{postId} → source contains both Uri.encodeComponent calls',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/users/{userId}/posts/{postId}',
              method: 'get',
              operationId: 'getUserPost',
              tags: ['user'],
              parameters: [
                ParameterObject(
                  name: 'userId',
                  location: 'path',
                  required: true,
                  schema: _strSchema,
                ),
                ParameterObject(
                  name: 'postId',
                  location: 'path',
                  required: true,
                  schema: _strSchema,
                ),
              ],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/user_api.dart');
        expect(src, contains('Uri.encodeComponent(userId)'));
        expect(src, contains('Uri.encodeComponent(postId)'));
      },
    );
  });

  // -------------------------------------------------------------------------
  // query parameters
  // -------------------------------------------------------------------------
  group('ServiceGenerator — query parameters', () {
    test(
      'optional query param page → source contains if (page != null) guard',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/items',
              method: 'get',
              operationId: 'listItems',
              tags: ['item'],
              parameters: [
                ParameterObject(
                  name: 'page',
                  location: 'query',
                  required: false,
                  schema: _intSchema,
                ),
              ],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/item_api.dart');
        expect(src, contains('if (page != null)'));
        expect(src, contains("queryParameters['page'] = page"));
      },
    );

    test('required query param → no null guard in queryParameters map', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/items',
            method: 'get',
            operationId: 'listItems',
            tags: ['item'],
            parameters: [
              ParameterObject(
                name: 'requiredParam',
                location: 'query',
                required: true,
                schema: _strSchema,
              ),
            ],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final src = _source(doc, 'services/item_api.dart');
      // Required param should appear without null guard
      expect(src, contains("'requiredParam': requiredParam"));
      // Should NOT have a null guard for this specific param
      expect(src, isNot(contains('if (requiredParam != null)')));
    });

    test(
      'location=querystring (3.2) → treated same as query, appears in queryParameters map',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/items',
              method: 'get',
              operationId: 'listItems',
              tags: ['item'],
              parameters: [
                ParameterObject(
                  name: 'filter',
                  location: 'querystring',
                  required: false,
                  schema: _strSchema,
                ),
              ],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/item_api.dart');
        expect(src, contains('queryParameters'));
        expect(src, contains("'filter'"));
      },
    );
  });

  // -------------------------------------------------------------------------
  // header parameters and merge
  // -------------------------------------------------------------------------
  group('ServiceGenerator — header parameters and merge', () {
    test(
      'header param x-request-id → method has String? xRequestId parameter',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/items',
              method: 'get',
              operationId: 'listItems',
              tags: ['item'],
              parameters: [
                ParameterObject(
                  name: 'x-request-id',
                  location: 'header',
                  required: false,
                  schema: _strSchema,
                ),
              ],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/item_api.dart');
        expect(src, contains('String? xRequestId'));
      },
    );

    test(
      'header param present → source contains {...specHeaders, ...?headers} merge pattern',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/items',
              method: 'get',
              operationId: 'listItems',
              tags: ['item'],
              parameters: [
                ParameterObject(
                  name: 'x-api-key',
                  location: 'header',
                  required: true,
                  schema: _strSchema,
                ),
              ],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/item_api.dart');
        expect(src, contains('specHeaders.addAll(headers)'));
      },
    );

    test(
      'no header params → source contains headers: headers (plain passthrough)',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/items',
              method: 'get',
              operationId: 'listItems',
              tags: ['item'],
              parameters: [],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/item_api.dart');
        expect(src, contains('headers: headers'));
        expect(src, isNot(contains('specHeaders')));
      },
    );
  });

  // -------------------------------------------------------------------------
  // request body
  // -------------------------------------------------------------------------
  group('ServiceGenerator — request body', () {
    test(
      'required request body with named schema → positional body parameter and data: body.toJson()',
      () {
        const userSchema = ObjectSchema(
          name: 'User',
          properties: [],
          required: [],
        );
        final doc = _makeDocWithSchemas(
          schemas: {'User': userSchema},
          operations: [
            const OperationItem(
              path: '/users',
              method: 'post',
              operationId: 'createUser',
              tags: ['user'],
              parameters: [],
              requestBody: RequestBodyObject(
                required: true,
                jsonSchema: ObjectSchema(
                  name: 'User',
                  properties: [],
                  required: [],
                ),
              ),
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/user_api.dart');
        expect(src, contains('User body'));
        expect(src, contains('data: body.toJson()'));
      },
    );

    test(
      'optional request body (required: false) → named optional body? parameter',
      () {
        const userSchema = ObjectSchema(
          name: 'User',
          properties: [],
          required: [],
        );
        final doc = _makeDocWithSchemas(
          schemas: {'User': userSchema},
          operations: [
            const OperationItem(
              path: '/users',
              method: 'post',
              operationId: 'createUser',
              tags: ['user'],
              parameters: [],
              requestBody: RequestBodyObject(
                required: false,
                jsonSchema: ObjectSchema(
                  name: 'User',
                  properties: [],
                  required: [],
                ),
              ),
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/user_api.dart');
        expect(src, contains('User? body'));
      },
    );
  });

  // -------------------------------------------------------------------------
  // 204 / void response
  // -------------------------------------------------------------------------
  group('ServiceGenerator — 204/void response', () {
    test(
      'responses with 204 and null jsonSchema → return type Future<void>',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/items/{id}',
              method: 'delete',
              operationId: 'deleteItem',
              tags: ['item'],
              parameters: [
                ParameterObject(
                  name: 'id',
                  location: 'path',
                  required: true,
                  schema: _strSchema,
                ),
              ],
              responses: {
                '204': ResponseObject(statusCode: '204', jsonSchema: null),
              },
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/item_api.dart');
        expect(src, contains('Future<void>'));
      },
    );

    test('Future<void> method does NOT contain .data!', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/items/{id}',
            method: 'delete',
            operationId: 'deleteItem',
            tags: ['item'],
            parameters: [
              ParameterObject(
                name: 'id',
                location: 'path',
                required: true,
                schema: _strSchema,
              ),
            ],
            responses: {
              '204': ResponseObject(statusCode: '204', jsonSchema: null),
            },
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final src = _source(doc, 'services/item_api.dart');
      expect(src, isNot(contains('.data!')));
    });
  });

  // -------------------------------------------------------------------------
  // array response
  // -------------------------------------------------------------------------
  group('ServiceGenerator — array response', () {
    test(
      'response with ArraySchema of named model → return type Future<List<Model>>',
      () {
        const userSchema = ObjectSchema(
          name: 'User',
          properties: [],
          required: [],
        );
        final doc = _makeDocWithSchemas(
          schemas: {'User': userSchema},
          operations: [
            const OperationItem(
              path: '/users',
              method: 'get',
              operationId: 'listUsers',
              tags: ['user'],
              parameters: [],
              responses: {
                '200': ResponseObject(
                  statusCode: '200',
                  jsonSchema: ArraySchema(
                    items: ObjectSchema(
                      name: 'User',
                      properties: [],
                      required: [],
                    ),
                  ),
                ),
              },
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/user_api.dart');
        expect(src, contains('Future<List<User>>'));
      },
    );

    test(
      'array response → source contains .map((e) => Model.fromJson(e as Map<String, dynamic>)).toList()',
      () {
        const userSchema = ObjectSchema(
          name: 'User',
          properties: [],
          required: [],
        );
        final doc = _makeDocWithSchemas(
          schemas: {'User': userSchema},
          operations: [
            const OperationItem(
              path: '/users',
              method: 'get',
              operationId: 'listUsers',
              tags: ['user'],
              parameters: [],
              responses: {
                '200': ResponseObject(
                  statusCode: '200',
                  jsonSchema: ArraySchema(
                    items: ObjectSchema(
                      name: 'User',
                      properties: [],
                      required: [],
                    ),
                  ),
                ),
              },
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/user_api.dart');
        expect(
          src,
          contains(
            '.map((e) => User.fromJson((e as Map<String, dynamic>))).toList()',
          ),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // Dio override params
  // -------------------------------------------------------------------------
  group('ServiceGenerator — Dio override params on every method', () {
    // Use a POST operation so all progress callbacks are included (Dio 5.x:
    // head/delete have no progress callbacks; get has only onReceiveProgress).
    late String src;

    setUp(() {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/items',
            method: 'post',
            operationId: 'createItem',
            tags: ['item'],
            parameters: [],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      src = _source(doc, 'services/item_api.dart');
    });

    test('every method contains CancelToken? cancelToken', () {
      expect(src, contains('CancelToken? cancelToken'));
    });

    test('every method contains Map<String, dynamic>? headers', () {
      expect(src, contains('Map<String, dynamic>? headers'));
    });

    test('every method contains Map<String, dynamic>? extra', () {
      expect(src, contains('Map<String, dynamic>? extra'));
    });

    test('every method contains ValidateStatus? validateStatus', () {
      expect(src, contains('ValidateStatus? validateStatus'));
    });

    test('every method contains ProgressCallback? onSendProgress', () {
      expect(src, contains('ProgressCallback? onSendProgress'));
    });

    test('every method contains ProgressCallback? onReceiveProgress', () {
      expect(src, contains('ProgressCallback? onReceiveProgress'));
    });
  });

  // -------------------------------------------------------------------------
  // Progress callback restrictions for head/delete (Dio 5.x compat)
  // -------------------------------------------------------------------------
  group('Progress callbacks omitted for head/delete', () {
    OperationItem makeSimpleOp(String method) => OperationItem(
      path: '/resource',
      method: method,
      operationId: '${method}Resource',
      tags: ['resource'],
      parameters: const [],
      responses: const {'200': _ok200},
      security: const [],
      additionalMethods: const [],
    );

    test(
      'head method does NOT include onSendProgress or onReceiveProgress',
      () {
        final doc = _makeDoc(operations: [makeSimpleOp('head')]);
        final src = _source(doc, 'services/resource_api.dart');
        expect(src, isNot(contains('ProgressCallback? onSendProgress')));
        expect(src, isNot(contains('ProgressCallback? onReceiveProgress')));
      },
    );

    test(
      'delete method does NOT include onSendProgress or onReceiveProgress',
      () {
        final doc = _makeDoc(operations: [makeSimpleOp('delete')]);
        final src = _source(doc, 'services/resource_api.dart');
        expect(src, isNot(contains('ProgressCallback? onSendProgress')));
        expect(src, isNot(contains('ProgressCallback? onReceiveProgress')));
      },
    );

    test(
      'get method does NOT include onSendProgress but includes onReceiveProgress',
      () {
        final doc = _makeDoc(operations: [makeSimpleOp('get')]);
        final src = _source(doc, 'services/resource_api.dart');
        expect(src, isNot(contains('ProgressCallback? onSendProgress')));
        expect(src, contains('ProgressCallback? onReceiveProgress'));
      },
    );
  });

  // -------------------------------------------------------------------------
  // dartdoc
  // -------------------------------------------------------------------------
  group('ServiceGenerator — dartdoc', () {
    test(
      'operation with summary "Get a user" → source contains /// Get a user',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/users/{id}',
              method: 'get',
              operationId: 'getUser',
              summary: 'Get a user',
              tags: ['user'],
              parameters: [
                ParameterObject(
                  name: 'id',
                  location: 'path',
                  required: true,
                  schema: _strSchema,
                ),
              ],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/user_api.dart');
        expect(src, contains('/// Get a user'));
      },
    );

    test(
      'parameter with description "User ID" → source contains /// - [id] User ID',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/users/{id}',
              method: 'get',
              operationId: 'getUser',
              tags: ['user'],
              parameters: [
                ParameterObject(
                  name: 'id',
                  location: 'path',
                  description: 'User ID',
                  required: true,
                  schema: _strSchema,
                ),
              ],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/user_api.dart');
        expect(src, contains('/// - [id] User ID'));
      },
    );

    test('source contains /// Throws [DioException] on non-2xx response', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/users',
            method: 'get',
            operationId: 'listUsers',
            tags: ['user'],
            parameters: [],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final src = _source(doc, 'services/user_api.dart');
      expect(src, contains('/// Throws [DioException] on non-2xx response'));
    });
  });

  // -------------------------------------------------------------------------
  // non-2xx error comment
  // -------------------------------------------------------------------------
  group('ServiceGenerator — non-2xx error comment', () {
    test(
      'operation with 400 response → source contains NOTE comment listing non-2xx codes',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/users',
              method: 'post',
              operationId: 'createUser',
              tags: ['user'],
              parameters: [],
              responses: {
                '200': _ok200,
                '400': ResponseObject(statusCode: '400'),
              },
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/user_api.dart');
        expect(src, contains('// NOTE: only 2xx responses are handled'));
        expect(src, contains('400'));
        expect(src, isNot(contains('// TODO:')));
      },
    );

    test(
      'operation with only 2xx responses → source does NOT contain error comment',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/users',
              method: 'get',
              operationId: 'listUsers',
              tags: ['user'],
              parameters: [],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/user_api.dart');
        expect(src, isNot(contains('// NOTE: only 2xx responses are handled')));
      },
    );
  });

  // -------------------------------------------------------------------------
  // Multiple tags — use tags[0] only
  // -------------------------------------------------------------------------
  group('ServiceGenerator — multiple tags use tags[0] only', () {
    test('op with tags [users, admin] → appears in services/user_api.dart', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/users',
            method: 'get',
            operationId: 'listUsers',
            tags: ['users', 'admin'],
            parameters: [],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final result = _makeGen(doc).generate(doc);
      expect(
        result.containsKey('services/users_api.dart'),
        isTrue,
        reason: 'Should use first tag "users" for file name',
      );
    });

    test('op with tags [users, admin] → NOT in services/admin_api.dart', () {
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/users',
            method: 'get',
            operationId: 'listUsers',
            tags: ['users', 'admin'],
            parameters: [],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      final result = _makeGen(doc).generate(doc);
      expect(result.containsKey('services/admin_api.dart'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Warning callbacks
  // -------------------------------------------------------------------------
  group('ServiceGenerator — warning callbacks', () {
    test(
      'op with no 2xx responses → onWarning called with operation identifier',
      () {
        final warnings = <String>[];
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/things',
              method: 'get',
              operationId: 'listThings',
              tags: ['thing'],
              parameters: [],
              responses: {'400': ResponseObject(statusCode: '400')},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        _source(doc, 'services/thing_api.dart', warnings: warnings);
        expect(warnings, isNotEmpty);
        expect(warnings.any((w) => w.contains('listThings')), isTrue);
      },
    );

    test(
      'op with only 201 response (no 200) → onWarning called mentioning 201',
      () {
        final warnings = <String>[];
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/things',
              method: 'post',
              operationId: 'createThing',
              tags: ['thing'],
              parameters: [],
              responses: {
                '201': ResponseObject(
                  statusCode: '201',
                  jsonSchema: PrimitiveSchema(primitiveType: 'string'),
                ),
              },
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        _source(doc, 'services/thing_api.dart', warnings: warnings);
        expect(warnings, isNotEmpty);
        expect(warnings.any((w) => w.contains('201')), isTrue);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Cookie params skipped
  // -------------------------------------------------------------------------
  group('ServiceGenerator — cookie params skipped', () {
    test(
      'op with cookie param session → method signature does NOT contain session parameter',
      () {
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/secure',
              method: 'get',
              operationId: 'getSecure',
              tags: ['secure'],
              parameters: [
                ParameterObject(
                  name: 'session',
                  location: 'cookie',
                  required: false,
                  schema: _strSchema,
                ),
              ],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/secure_api.dart');
        // session should not appear as a parameter (only as part of class/doc text potentially)
        // Check the method signature area doesn't have 'String? session'
        expect(src, isNot(contains('String? session')));
      },
    );

    test('op with cookie param → onWarning called', () {
      final warnings = <String>[];
      final doc = _makeDoc(
        operations: [
          const OperationItem(
            path: '/secure',
            method: 'get',
            operationId: 'getSecure',
            tags: ['secure'],
            parameters: [
              ParameterObject(
                name: 'session',
                location: 'cookie',
                required: false,
                schema: _strSchema,
              ),
            ],
            responses: {'200': _ok200},
            security: [],
            additionalMethods: [],
          ),
        ],
      );
      _source(doc, 'services/secure_api.dart', warnings: warnings);
      expect(warnings, isNotEmpty);
      expect(warnings.any((w) => w.contains('cookie')), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // additionalMethod warnings (OpenAPI 3.2 non-standard verbs)
  // -------------------------------------------------------------------------
  group('ServiceGenerator — additionalMethod warnings', () {
    test(
      'op with additionalMethods: [QUERY] → onWarning called containing QUERY',
      () {
        final warnings = <String>[];
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/items',
              method: 'get',
              operationId: 'listItems',
              tags: ['item'],
              parameters: [],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: ['QUERY'],
            ),
          ],
        );
        _source(doc, 'services/item_api.dart', warnings: warnings);
        expect(warnings, isNotEmpty);
        expect(warnings.any((w) => w.contains('QUERY')), isTrue);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Inline anonymous response schema (Pitfall 6 / _schemaToType fallback)
  // -------------------------------------------------------------------------
  group('ServiceGenerator — inline anonymous response schema fallback', () {
    test(
      'inline response schema registered in registry → emitted return type is computed class name',
      () {
        // The NameRegistry registers inline response schemas using the operation base name.
        // For operationId 'getWidget', the registry key is 'GetWidgetResponse'.
        // We need to provide the schema as a ResponseObject with a non-null jsonSchema
        // that has name == null (inline/anonymous). The registry will pick up
        // 'GetWidgetResponse' from pass-1 collection.
        final inlineSchema = const ObjectSchema(
          // name is null — anonymous inline schema
          properties: [],
          required: [],
        );

        final doc = _makeDocWithSchemas(
          schemas: const {},
          operations: [
            OperationItem(
              path: '/widgets',
              method: 'get',
              operationId: 'getWidget',
              tags: ['widget'],
              parameters: const [],
              responses: {
                '200': ResponseObject(
                  statusCode: '200',
                  jsonSchema: inlineSchema,
                ),
              },
              security: const [],
              additionalMethods: const [],
            ),
          ],
        );
        final src = _source(doc, 'services/widget_api.dart');
        // NameRegistry registers 'GetWidgetResponse' from the inline schema collection pass.
        // ServiceGenerator should resolve it to 'GetWidgetResponse' class name.
        expect(src, contains('GetWidgetResponse'));
        // Return type should be Future<GetWidgetResponse>, not Future<Map<String, dynamic>>
        expect(src, contains('Future<GetWidgetResponse>'));
        expect(src, isNot(contains('Future<Map<String, dynamic>>')));
      },
    );

    test(
      'genuinely anonymous response schema not in registry → emitted return type is Map<String, dynamic>',
      () {
        // Build a doc where the response schema has name=null but there is NO
        // matching operationId-based registry entry (simulate by using a doc with
        // schemas only and a manually-constructed operation not registered in the registry).
        // The simplest approach: create a SpecDocument that has a response schema
        // but build a registry from a DIFFERENT doc that has no operations (no inline schemas).
        // Then call ServiceGenerator directly with the mis-matched registry.
        final emptyDoc = _makeDoc(); // registry built from empty doc
        final registry = buildNameRegistry(emptyDoc);

        final inlineSchema = const ObjectSchema(properties: [], required: []);

        final operationDoc = _makeDoc(
          operations: [
            OperationItem(
              path: '/unknown',
              method: 'get',
              operationId: 'unknownOp',
              tags: ['unknown'],
              parameters: const [],
              responses: {
                '200': ResponseObject(
                  statusCode: '200',
                  jsonSchema: inlineSchema,
                ),
              },
              security: const [],
              additionalMethods: const [],
            ),
          ],
        );

        // Build the generator using the empty registry (no inline schemas registered)
        final gen = ServiceGenerator(registry);
        final result = gen.generate(operationDoc);
        final src =
            result['services/unknown_api.dart'] ??
            (throw StateError('File not found'));

        expect(src, contains('Map<String, dynamic>'));
      },
    );
  });

  // -------------------------------------------------------------------------
  // Alphabetical ordering (D2)
  // -------------------------------------------------------------------------
  group('ServiceGenerator — alphabetical ordering (D2)', () {
    test(
      'two ops in same tag: second name alphabetically first → methods appear in alphabetical order',
      () {
        // operationId 'zMethod' → method name 'zmethod' (toPascalCase normalizes to 'Zmethod')
        // operationId 'aMethod' → method name 'amethod' (toPascalCase normalizes to 'Amethod')
        // 'amethod' < 'zmethod' alphabetically, so 'amethod' should appear first.
        final doc = _makeDoc(
          operations: [
            const OperationItem(
              path: '/resources',
              method: 'post',
              operationId: 'zMethod',
              tags: ['api'],
              parameters: [],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
            const OperationItem(
              path: '/resources',
              method: 'get',
              operationId: 'aMethod',
              tags: ['api'],
              parameters: [],
              responses: {'200': _ok200},
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/api_api.dart');
        // toPascalCase normalizes identifiers: 'aMethod'→'Amethod', 'zMethod'→'Zmethod'
        // → Dart method names: 'amethod' and 'zmethod'
        final aIdx = src.indexOf('amethod(');
        final zIdx = src.indexOf('zmethod(');
        expect(aIdx, isNot(-1), reason: 'amethod should be present');
        expect(zIdx, isNot(-1), reason: 'zmethod should be present');
        expect(
          aIdx,
          lessThan(zIdx),
          reason: 'amethod must appear before zmethod (alphabetical order)',
        );
      },
    );

    test(
      'imports appear in sorted order — model imports are sorted alphabetically',
      () {
        // Two operations in same tag with different named model responses
        const alphaSchema = ObjectSchema(
          name: 'Alpha',
          properties: [],
          required: [],
        );
        const zetaSchema = ObjectSchema(
          name: 'Zeta',
          properties: [],
          required: [],
        );
        final doc = _makeDocWithSchemas(
          schemas: {'Alpha': alphaSchema, 'Zeta': zetaSchema},
          operations: [
            const OperationItem(
              path: '/zeta',
              method: 'get',
              operationId: 'getZeta',
              tags: ['mixed'],
              parameters: [],
              responses: {
                '200': ResponseObject(
                  statusCode: '200',
                  jsonSchema: ObjectSchema(
                    name: 'Zeta',
                    properties: [],
                    required: [],
                  ),
                ),
              },
              security: [],
              additionalMethods: [],
            ),
            const OperationItem(
              path: '/alpha',
              method: 'get',
              operationId: 'getAlpha',
              tags: ['mixed'],
              parameters: [],
              responses: {
                '200': ResponseObject(
                  statusCode: '200',
                  jsonSchema: ObjectSchema(
                    name: 'Alpha',
                    properties: [],
                    required: [],
                  ),
                ),
              },
              security: [],
              additionalMethods: [],
            ),
          ],
        );
        final src = _source(doc, 'services/mixed_api.dart');
        // alpha.dart import should appear before zeta.dart import
        final alphaImportIdx = src.indexOf("import '../models/alpha.dart'");
        final zetaImportIdx = src.indexOf("import '../models/zeta.dart'");
        expect(
          alphaImportIdx,
          isNot(-1),
          reason: 'alpha.dart import should be present',
        );
        expect(
          zetaImportIdx,
          isNot(-1),
          reason: 'zeta.dart import should be present',
        );
        expect(
          alphaImportIdx,
          lessThan(zetaImportIdx),
          reason: 'alpha.dart import must appear before zeta.dart import',
        );
      },
    );
  });
}
