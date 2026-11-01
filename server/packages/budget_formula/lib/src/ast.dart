import 'package:decimal/decimal.dart';
import 'package:rational/rational.dart';

enum UnaryOp { plus, minus }

enum BinaryOp { add, subtract, multiply, divide, power }

/// A parsed formula. Spans are UTF-16 offsets into the source text.
sealed class Expr {
  int get start;
  int get end;
}

/// A number literal; [currency] when written `$100` (money fields only).
class NumberLit extends Expr {
  final Decimal value;
  final String lexeme;
  final bool currency;
  @override
  final int start;
  @override
  final int end;
  NumberLit(this.value, this.lexeme, this.start, this.end,
      {this.currency = false});

  /// [value] as a rational (cached).
  late final Rational rational = value.toRational();
}

class VarRef extends Expr {
  /// Without `$`, as typed.
  final String name;
  @override
  final int start;
  @override
  final int end;
  VarRef(this.name, this.start, this.end);
  String get lowerName => name.toLowerCase();
}

class Unary extends Expr {
  final UnaryOp op;
  final Expr operand;
  final int opStart;
  Unary(this.op, this.operand, this.opStart);
  @override
  int get start => opStart;
  @override
  int get end => operand.end;
}

class Binary extends Expr {
  final BinaryOp op;
  final Expr left;
  final Expr right;
  final int opStart;
  Binary(this.op, this.left, this.right, this.opStart);
  @override
  int get start => left.start;
  @override
  int get end => right.end;
}

/// Brackets, kept so the printer reproduces them.
class Group extends Expr {
  final Expr inner;
  @override
  final int start;
  @override
  final int end;
  Group(this.inner, this.start, this.end);
}

/// Reserved (dialect `percentLiterals`): `5%` = 5 / 100.
class PercentLit extends Expr {
  final Expr operand;
  @override
  final int end;
  PercentLit(this.operand, this.end);
  @override
  int get start => operand.start;
}

/// Reserved (dialect `functions`): `round($x / 7)`.
class Call extends Expr {
  final String fn;
  final List<Expr> args;
  @override
  final int start;
  @override
  final int end;
  Call(this.fn, this.args, this.start, this.end);
}

/// Visits [e] and every descendant (pre-order).
Iterable<Expr> walkExpr(Expr e) sync* {
  yield e;
  switch (e) {
    case NumberLit() || VarRef():
      break;
    case Unary(:final operand) || PercentLit(:final operand):
      yield* walkExpr(operand);
    case Binary(:final left, :final right):
      yield* walkExpr(left);
      yield* walkExpr(right);
    case Group(:final inner):
      yield* walkExpr(inner);
    case Call(:final args):
      for (final a in args) {
        yield* walkExpr(a);
      }
  }
}
