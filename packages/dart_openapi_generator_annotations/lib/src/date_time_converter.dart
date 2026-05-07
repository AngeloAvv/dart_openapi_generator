/// Strategy for serializing `string` + `date-time` schema fields.
///
/// Passed as [OpenApiGenerator.dateTimeConverter]. Determines how generated
/// `fromJson` and `toJson` methods handle [DateTime] values.
///
/// See [OpenApiGenerator] for full usage.
enum DateTimeConverter {
  /// Serialize/deserialize [DateTime] using ISO 8601 strings.
  ///
  /// `fromJson`: `DateTime.parse(json['field'] as String)`
  /// `toJson`:   `instance.field.toIso8601String()`
  ///
  /// This is the default strategy.
  iso8601,

  /// Serialize/deserialize [DateTime] using milliseconds since Unix epoch.
  ///
  /// `fromJson`: `DateTime.fromMillisecondsSinceEpoch(json['field'] as int)`
  /// `toJson`:   `instance.field.millisecondsSinceEpoch`
  timestamp,
}
