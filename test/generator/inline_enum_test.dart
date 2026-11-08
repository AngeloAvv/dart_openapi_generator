import 'package:test/test.dart';

import '../support/fixtures.dart';

/// Inline `enum` properties (issue #22): generated as an enum class named
/// `<Owner><Property>`, not as `dynamic`.
void main() {
  late Map<String, String> files;
  late List<String> warnings;

  setUpAll(() async {
    final generated = await generateFixture('inline_enums.yaml');
    files = generated.files;
    warnings = generated.warnings;
  });

  String model(String file) =>
      files['models/$file'] ?? (throw StateError('No $file: ${files.keys}'));

  group('inline enum properties', () {
    test('required properties are typed with their own enum class', () {
      final ticket = model('ticket.dart');
      expect(ticket, contains('final TicketStatus status;'));
      expect(ticket, contains('final TicketPriority priority;'));
      expect(
        ticket,
        contains("TicketStatus.fromJson(json['status'] as String)"),
      );
      expect(ticket, contains('status.toJson()'));
    });

    test('nothing is dynamic', () {
      for (final MapEntry(:key, :value) in files.entries) {
        expect(value, isNot(contains('as dynamic')), reason: key);
        expect(value, isNot(contains('dynamic?')), reason: key);
      }
    });

    test('a single-value enum gets a class too', () {
      expect(model('ticket_status.dart'), contains('enum TicketStatus'));
      expect(model('ticket_status.dart'), contains('open'));
    });

    test('a multi-value enum keeps every value', () {
      final source = model('ticket_priority.dart');
      expect(source, contains('enum TicketPriority'));
      expect(source, contains('high'));
      expect(source, contains('low'));
    });

    test('optional and nullable properties are nullable enums', () {
      final ticket = model('ticket.dart');
      expect(ticket, contains('final TicketResolution? resolution;'));
      expect(ticket, contains('final TicketSeverity? severity;'));
    });

    test('an enum with an integer wire type keeps it', () {
      final source = model('create_ticket_request_severity.dart');
      expect(source, contains('enum CreateTicketRequestSeverity'));
      expect(
        source,
        contains('static CreateTicketRequestSeverity fromJson(int v)'),
      );
    });

    test('enum items of an array property are typed', () {
      expect(
        model('ticket.dart'),
        contains('final List<TicketLabels>? labels;'),
      );
      expect(model('ticket_labels.dart'), contains('enum TicketLabels'));
    });

    test('an inline request body gets enum classes for its properties', () {
      final request = model('create_ticket_request.dart');
      expect(request, contains('final CreateTicketRequestSeverity severity;'));
    });

    test('an inline response gets enum classes for its properties', () {
      final response = model('list_tickets_response.dart');
      expect(response, contains('final ListTicketsResponseKind kind;'));
    });

    test('properties inherited through allOf are typed', () {
      final archived = model('archived.dart');
      expect(archived, contains('TicketStatus status'));
      expect(archived, contains('ArchivedReason? reason'));
    });

    test('a component that owns the name is not shadowed', () {
      final ticket = model('ticket.dart');
      // `TicketKind` is the user's component; the inline enum takes another name.
      expect(ticket, contains('final TicketKind2? kind;'));
      expect(model('ticket_kind.dart'), contains('change'));
    });

    test('an inline enum parameter is its wire type', () {
      final service = files['services/tickets_api.dart']!;
      expect(service, contains('String? sort'));
      expect(service, isNot(contains('Map<String, dynamic>? sort')));
    });

    test('no warning reports an untyped property', () {
      expect(warnings.where((w) => w.contains('dynamic')), isEmpty);
    });
  });
}
