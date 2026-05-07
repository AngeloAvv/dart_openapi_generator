import 'package:build/build.dart';

import 'src/builder/open_api_builder.dart';

/// Factory function wired into build.yaml under [builder_factories].
///
/// Returns an [OpenApiBuilder] instance. [options] are accepted for
/// future configuration but currently unused.
Builder dartOpenApiBuilder(BuilderOptions options) => OpenApiBuilder();
