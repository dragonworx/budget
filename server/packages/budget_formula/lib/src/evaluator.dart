import 'package:decimal/decimal.dart';
import 'package:rational/rational.dart';

import 'ast.dart';
import 'dialect.dart';
import 'errors.dart';
import 'names.dart';
import 'rounding.dart';

/// A variable's unit: drives display and hints only (evaluation is
/// unit-free).
enum VariableUnit { money, percent, number }

class VariableValue {
  /// Canonical case.
  final String name;
  final Decimal value;
  final VariableUnit unit;
  VariableValue(this.name, this.value, this.unit);

  /// [value] as a rational (cached: a lookup is evaluated many times).
  late final Rational rational = value.toRational();

  @override
  String toString() => '$name=$value(${unit.name})';
}

/// Resolves variable names. Implement [lookup]; override [values] to get
/// "did you mean" hints for unknown names.
abstract class VariableLookup {
  const VariableLookup();

  /// [lowerName] is lower-case.
  VariableValue? lookup(String lowerName);

  /// Every known variable (for hints); empty by default.
  Iterable<VariableValue> get values => const [];

  static const VariableLookup none = MapVariableLookup.empty();
}

/// A [VariableLookup] over a list.
class MapVariableLookup extends VariableLookup {
  final Map<String, VariableValue> _byLower;
  MapVariableLookup(Iterable<VariableValue> vars)
      : _byLower = {for (final v in vars) v.name.toLowerCase(): v};
  const MapVariableLookup.empty() : _byLower = const {};

  @override
  VariableValue? lookup(String lowerName) => _byLower[lowerName];

  @override
  Iterable<VariableValue> get values => _byLower.values;
}

sealed class EvalResult {}

class EvalOk extends EvalResult {
  final Rational value;

  /// Lower-case names of every variable the formula used.
  final Set<String> usedLower;
  EvalOk(this.value, this.usedLower);
}

class EvalErr extends EvalResult {
  final FormulaError error;
  EvalErr(this.error);
}

/// No intermediate may exceed this magnitude.
final Rational maxMagnitude = Rational(BigInt.from(10).pow(15));

/// Numerators/denominators above this many bits are rounded to 30 dp.
const int maxRationalBits = 256;

class _EvalFail implements Exception {
  final FormulaError error;
  _EvalFail(this.error);
}

/// Evaluates [e] exactly (rational arithmetic, left to right; the first
/// error wins). Never throws on user input.
EvalResult evaluate(Expr e, VariableLookup vars,
    {FormulaDialect dialect = FormulaDialect.v1}) {
  final used = <String>{};
  try {
    return EvalOk(_Eval(vars, used, dialect).eval(e), used);
  } on _EvalFail catch (f) {
    return EvalErr(f.error);
  }
}

class _Eval {
  final VariableLookup vars;
  final Set<String> used;
  final FormulaDialect dialect;
  _Eval(this.vars, this.used, this.dialect);

  Never fail(FormulaErrorCode c, String m, int s, int e, {String? hint}) =>
      throw _EvalFail(FormulaError(c, m, s, e, hint: hint));

  static final BigInt _maxMag = BigInt.from(10).pow(15);

  /// The overflow and size rules on every intermediate: |r| <= 10^15, and
  /// a reduced numerator/denominator above [maxRationalBits] bits is
  /// rounded to 30 dp.
  _Q check(_Q r, Expr at) {
    // Fast path: |n| < 2^49 < 10^15 <= 10^15 * d, and small enough.
    if (r.n.bitLength < 50 && r.d.bitLength <= maxRationalBits) return r;
    if (r.n.abs() > _maxMag * r.d) {
      fail(FormulaErrorCode.overflow, 'This works out too large', at.start,
          at.end);
    }
    if (r.n.bitLength > maxRationalBits || r.d.bitLength > maxRationalBits) {
      r = r.reduced();
      if (r.n.bitLength > maxRationalBits || r.d.bitLength > maxRationalBits) {
        r = _Q.of(roundHalfAwayFromZero(r.toRational(), 30).toRational());
      }
    }
    return r;
  }

  Rational eval(Expr e) => _eval(e).toRational();

  _Q _eval(Expr e) {
    switch (e) {
      case NumberLit():
        return check(_Q.of(e.rational), e);
      case VarRef():
        final v = vars.lookup(e.lowerName);
        if (v == null) {
          final close =
              closestName(e.name, [for (final x in vars.values) x.name]);
          fail(
              FormulaErrorCode.unknownVariable,
              close == null
                  ? 'Unknown variable ${e.name}'
                  : 'Unknown variable ${e.name} (did you mean $close?)',
              e.start,
              e.end,
              hint: close == null ? null : 'Did you mean $close?');
        }
        used.add(e.lowerName);
        return check(_Q.of(v.rational), e);
      case Unary(:final op, :final operand):
        final v = _eval(operand);
        return op == UnaryOp.minus ? _Q(-v.n, v.d) : v;
      case Group(:final inner):
        return _eval(inner);
      case Binary(:final op, :final left, :final right, :final opStart):
        final a = _eval(left);
        final b = _eval(right);
        switch (op) {
          case BinaryOp.add:
            return check(a + b, e);
          case BinaryOp.subtract:
            return check(a - b, e);
          case BinaryOp.multiply:
            return check(a * b, e);
          case BinaryOp.divide:
            if (b.n == BigInt.zero) {
              final r = _bare(right);
              final name = r is VarRef
                  ? (vars.lookup(r.lowerName)?.name ?? r.name)
                  : null;
              fail(
                  FormulaErrorCode.divisionByZero,
                  name == null
                      ? 'Division by zero'
                      : 'Division by zero: $name is 0',
                  opStart,
                  opStart + 1);
            }
            return check(a / b, e);
          case BinaryOp.power:
            final br = b.toRational();
            if (!isWhole(br) || br.abs() > Rational.fromInt(64)) {
              fail(
                  FormulaErrorCode.unexpectedToken,
                  'Powers must be whole numbers up to 64',
                  right.start,
                  right.end);
            }
            final n = br.numerator.toInt();
            if (a.n == BigInt.zero && n < 0) {
              fail(FormulaErrorCode.divisionByZero, 'Division by zero', opStart,
                  opStart + 1);
            }
            var r = _Q.one;
            for (var i = 0; i < n.abs(); i++) {
              r = check(r * a, e);
            }
            return check(n < 0 ? _Q.one / r : r, e);
        }
      case PercentLit(:final operand):
        return check(_eval(operand) / _Q(BigInt.from(100), BigInt.one), e);
      case Call(:final fn, :final args):
        final f = dialect.functions[fn];
        if (f == null) {
          fail(FormulaErrorCode.reservedSyntax,
              "Functions like round() aren't supported yet", e.start, e.end);
        }
        return check(
            _Q.of(f.impl([for (final a in args) _eval(a).toRational()])), e);
    }
  }

  /// [e] without surrounding brackets.
  Expr _bare(Expr e) => e is Group ? _bare(e.inner) : e;
}

/// An exact fraction kept unreduced between operations (d > 0); reduced
/// only when it grows large and once at the end, which saves a gcd per
/// operation. Same values as [Rational] throughout.
class _Q {
  final BigInt n, d;
  const _Q(this.n, this.d);
  static final _Q one = _Q(BigInt.one, BigInt.one);
  factory _Q.of(Rational r) => _Q(r.numerator, r.denominator);

  _Q operator +(_Q o) =>
      d == o.d ? _Q(n + o.n, d) : _Q(n * o.d + o.n * d, d * o.d);
  _Q operator -(_Q o) =>
      d == o.d ? _Q(n - o.n, d) : _Q(n * o.d - o.n * d, d * o.d);
  _Q operator *(_Q o) => _Q(n * o.n, d * o.d);
  _Q operator /(_Q o) =>
      o.n.isNegative ? _Q(-n * o.d, d * -o.n) : _Q(n * o.d, d * o.n);

  _Q reduced() {
    final g = n.gcd(d);
    return g == BigInt.one || g == BigInt.zero ? this : _Q(n ~/ g, d ~/ g);
  }

  Rational toRational() => Rational(n, d);
}
