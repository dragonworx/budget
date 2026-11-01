import 'ast.dart';

/// Canonical one-line form: ASCII operators, one space around binary
/// operators, none after a sign, brackets as typed.
String prettyPrint(Expr e) => switch (e) {
      NumberLit(:final lexeme, :final currency) =>
        currency ? '\$$lexeme' : lexeme,
      VarRef(:final name) => '\$$name',
      Unary(:final op, :final operand) =>
        '${op == UnaryOp.minus ? '-' : '+'}${prettyPrint(operand)}',
      Binary(:final op, :final left, :final right) =>
        '${prettyPrint(left)} ${_op(op)} ${prettyPrint(right)}',
      Group(:final inner) => '(${prettyPrint(inner)})',
      PercentLit(:final operand) => '${prettyPrint(operand)}%',
      Call(:final fn, :final args) =>
        '$fn(${args.map(prettyPrint).join(', ')})',
    };

String _op(BinaryOp op) => switch (op) {
      BinaryOp.add => '+',
      BinaryOp.subtract => '-',
      BinaryOp.multiply => '*',
      BinaryOp.divide => '/',
      BinaryOp.power => '^',
    };

/// An indented tree dump (goldens and debugging).
String dumpAst(Expr e, [String indent = '']) {
  final head = switch (e) {
    NumberLit(:final value, :final currency) =>
      'Number $value${currency ? ' (currency)' : ''}',
    VarRef(:final name) => 'Var \$$name',
    Unary(:final op) => 'Unary ${op.name}',
    Binary(:final op) => 'Binary ${op.name}',
    Group() => 'Group',
    PercentLit() => 'Percent',
    Call(:final fn) => 'Call $fn',
  };
  final b = StringBuffer('$indent$head [${e.start},${e.end})\n');
  final kids = switch (e) {
    NumberLit() || VarRef() => const <Expr>[],
    Unary(:final operand) || PercentLit(:final operand) => [operand],
    Binary(:final left, :final right) => [left, right],
    Group(:final inner) => [inner],
    Call(:final args) => args,
  };
  for (final k in kids) {
    b.write(dumpAst(k, '$indent  '));
  }
  return b.toString();
}
