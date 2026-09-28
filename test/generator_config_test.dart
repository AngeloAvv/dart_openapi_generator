import 'package:build/build.dart';
import 'package:dart_openapi_generator/src/date_time_converter.dart';
import 'package:dart_openapi_generator/src/generator_config.dart';
import 'package:dart_openapi_generator/src/model_class_modifier.dart';
import 'package:test/test.dart';

GeneratorConfig _fromConfig(Map<String, dynamic> config) =>
    GeneratorConfig.fromBuilderOptions(BuilderOptions(config));

void main() {
  group('required fields', () {
    test('missing input_spec throws ArgumentError', () {
      expect(
        () => _fromConfig({'output_dir': 'lib/generated'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('input_spec'),
          ),
        ),
      );
    });

    test('empty input_spec throws ArgumentError', () {
      expect(
        () => _fromConfig({'input_spec': '', 'output_dir': 'lib/generated'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('missing output_dir throws ArgumentError', () {
      expect(
        () => _fromConfig({'input_spec': 'openapi.yaml'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('output_dir'),
          ),
        ),
      );
    });
  });

  group('defaults', () {
    test('clientName defaults to ApiClient', () {
      final config = _fromConfig({
        'input_spec': 'openapi.yaml',
        'output_dir': 'lib/generated',
      });
      expect(config.clientName, equals('ApiClient'));
    });

    test('dateTimeConverter defaults to iso8601', () {
      final config = _fromConfig({
        'input_spec': 'openapi.yaml',
        'output_dir': 'lib/generated',
      });
      expect(config.dateTimeConverter, equals(DateTimeConverter.iso8601));
    });

    test('debugLogging defaults to false', () {
      final config = _fromConfig({
        'input_spec': 'openapi.yaml',
        'output_dir': 'lib/generated',
      });
      expect(config.debugLogging, isFalse);
    });
  });

  group('date_time_converter parsing', () {
    test('"timestamp" resolves to DateTimeConverter.timestamp', () {
      final config = _fromConfig({
        'input_spec': 'openapi.yaml',
        'output_dir': 'lib/generated',
        'date_time_converter': 'timestamp',
      });
      expect(config.dateTimeConverter, equals(DateTimeConverter.timestamp));
    });

    test('unknown value throws ArgumentError', () {
      expect(
        () => _fromConfig({
          'input_spec': 'openapi.yaml',
          'output_dir': 'lib/generated',
          'date_time_converter': 'not_a_real_value',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('model_class_modifier parsing', () {
    test(r'defaults to ModelClassModifier.final$ when absent', () {
      final config = _fromConfig({
        'input_spec': 'openapi.yaml',
        'output_dir': 'lib/generated',
      });
      expect(config.modelClassModifier, equals(ModelClassModifier.final$));
    });

    test(r'"final" resolves to ModelClassModifier.final$', () {
      final config = _fromConfig({
        'input_spec': 'openapi.yaml',
        'output_dir': 'lib/generated',
        'model_class_modifier': 'final',
      });
      expect(config.modelClassModifier, equals(ModelClassModifier.final$));
    });

    test('"none" resolves to ModelClassModifier.none', () {
      final config = _fromConfig({
        'input_spec': 'openapi.yaml',
        'output_dir': 'lib/generated',
        'model_class_modifier': 'none',
      });
      expect(config.modelClassModifier, equals(ModelClassModifier.none));
    });

    test(r'"final$" is rejected — the $ is a Dart artifact, not config', () {
      expect(
        () => _fromConfig({
          'input_spec': 'openapi.yaml',
          'output_dir': 'lib/generated',
          'model_class_modifier': r'final$',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('unknown value throws ArgumentError listing the valid ones', () {
      expect(
        () => _fromConfig({
          'input_spec': 'openapi.yaml',
          'output_dir': 'lib/generated',
          'model_class_modifier': 'interface',
        }),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('final'), contains('none')),
          ),
        ),
      );
    });

    test('non-string value throws ArgumentError', () {
      expect(
        () => _fromConfig({
          'input_spec': 'openapi.yaml',
          'output_dir': 'lib/generated',
          'model_class_modifier': true,
        }),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('explicit overrides', () {
    test('all fields are read from config when provided', () {
      final config = _fromConfig({
        'input_spec': 'openapi.yaml',
        'output_dir': 'lib/generated',
        'client_name': 'PetClient',
        'date_time_converter': 'timestamp',
        'model_class_modifier': 'none',
        'debug_logging': true,
      });
      expect(config.inputSpec, equals('openapi.yaml'));
      expect(config.outputDir, equals('lib/generated'));
      expect(config.clientName, equals('PetClient'));
      expect(config.dateTimeConverter, equals(DateTimeConverter.timestamp));
      expect(config.modelClassModifier, equals(ModelClassModifier.none));
      expect(config.debugLogging, isTrue);
    });
  });
}
