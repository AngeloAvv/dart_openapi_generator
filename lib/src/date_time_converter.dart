/// Strategy used to (de)serialize `DateTime` fields in generated models.
enum DateTimeConverter {
  /// ISO-8601 string representation (`DateTime.parse`/`toIso8601String`).
  iso8601,

  /// Unix epoch milliseconds (`DateTime.fromMillisecondsSinceEpoch`/
  /// `millisecondsSinceEpoch`).
  timestamp,
}
