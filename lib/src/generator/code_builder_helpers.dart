import 'package:code_builder/code_builder.dart';

/// Builds: `if (condition) { then } [else { otherwise }]`
Block ifStatement(
  Expression condition, {
  required Block then,
  Block? otherwise,
}) => Block((b) {
  b.statements.addAll([
    Code('if'),
    condition.parenthesized.code,
    Code('{'),
    ...then.statements,
    Code('}'),
    if (otherwise != null) ...[
      Code('else {'),
      ...otherwise.statements,
      Code('}'),
    ],
  ]);
});

/// Builds: `for (var $variable = 0; $variable < upper; $variable++) { body }`
Block forIndexStatement(
  String variable,
  Expression upper, {
  required Block body,
}) => Block((b) {
  b.statements.addAll([
    Code('for (var $variable = 0; '),
    refer(variable).lessThan(upper).code,
    Code('; $variable++) {'),
    ...body.statements,
    Code('}'),
  ]);
});

/// Builds: `for (final $variable in iterable) { body }`
Block forEachStatement(
  String variable,
  Expression iterable, {
  required Block body,
}) => Block((b) {
  b.statements.addAll([
    Code('for (final $variable in '),
    iterable.code,
    Code(') {'),
    ...body.statements,
    Code('}'),
  ]);
});

/// Builds: `switch (condition) { case1 => result1, ..., [_ => otherwise] }`
Expression returnSwitch(
  Expression condition, {
  required Iterable<(Expression, Expression)> cases,
  Expression? otherwise,
}) => CodeExpression(
  Block((b) {
    b.statements.addAll([
      Code('switch'),
      condition.parenthesized.code,
      Code('{'),
      for (final c in cases) ...[c.$1.arrowReturn(c.$2).code, Code(',')],
      if (otherwise != null) ...[
        refer('_').arrowReturn(otherwise).code,
        Code(','),
      ],
      Code('}'),
    ]);
  }),
);

extension ExpressionHelpers on Expression {
  /// Emits `this => result`.
  Expression arrowReturn(Expression result) =>
      CodeExpression(Block.of([code, Code('=>'), result.code]));
}
