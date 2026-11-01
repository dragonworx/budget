import 'package:decimal/decimal.dart';
import 'package:rational/rational.dart';

final BigInt _ten = BigInt.from(10);

/// [r] rounded to [scale] decimal places, half away from zero
/// (`2.675 → 2.68`, `-2.675 → -2.68`), on integers only.
Decimal roundHalfAwayFromZero(Rational r, int scale) {
  final p = _ten.pow(scale);
  final n = r.numerator * p;
  final d = r.denominator; // always positive
  final a = n.abs();
  var q = a ~/ d;
  if ((a.remainder(d)) * BigInt.two >= d) q += BigInt.one;
  if (n.isNegative) q = -q;
  return Decimal.fromBigInt(q).shift(-scale);
}

/// Whether [r] is an integer.
bool isWhole(Rational r) => r.denominator == BigInt.one;

/// [d] as a plain string with at most [maxScale] decimals, trailing zeros
/// dropped ("10.4", "3", "0.3333").
String plainDecimal(Rational r, {int maxScale = 4}) {
  final d = roundHalfAwayFromZero(r, maxScale);
  return d.toString();
}
