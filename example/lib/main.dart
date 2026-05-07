import 'package:dart_openapi_generator_annotations/dart_openapi_generator_annotations.dart';

import 'generated/generated.dart';

/// Marker class that triggers OpenAPI code generation via build_runner.
///
/// Run `dart run build_runner build` in this directory to generate:
/// - lib/generated/models/         (one .dart file per schema)
/// - lib/generated/services/       (one .dart file per tag)
/// - lib/generated/api_client.dart (ExampleApiClient with auth factories)
/// - lib/generated/generated.dart  (barrel export)
@OpenApiGenerator(
  inputSpec: LocalSpec('openapi/example_api.yaml'),
  outputDir: 'lib/generated',
  clientName: 'ExampleApiClient',
  debugLogging: true,
)
class $ExampleApp {}

void main() {
  final client = ExampleApiClient(
    baseUrl: 'https://api.example.com/v1',
    interceptors: [
      ExampleApiClient.bearerAuth('your-bearer-token'),
    ],
  );

  // Example usage — run build_runner first to generate ExampleApiClient:
  // await client.users.listUsers();
  // await client.users.getUser('user-id');
  // await client.users.createUser(User(id: '1', name: 'Alice', email: 'alice@example.com'));
  // await client.auth.createToken(TokenRequest(username: 'alice', password: 'secret'));
  // await client.categories.listCategories();

  // Other available auth factories (generated from securitySchemes in the spec):
  // ExampleApiClient.apiKeyAuth('my-key', headerName: 'X-Api-Key')
  // ExampleApiClient.apiKeyQueryAuth('my-key', paramName: 'api_key')
  // ExampleApiClient.basicAuth('user', 'password')

  print(client.runtimeType);
}
