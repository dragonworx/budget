/// Plain-number parsers, behaviour-identical to each field's code today
/// (D14: when one accepts the input it's a plain number, stored as today).
library;

import 'package:decimal/decimal.dart';

/// Today's `parseMoneyInput` (client/lib/widgets/money_text.dart), moved
/// here verbatim: tolerates thousands separators, spaces and a leading
/// currency symbol or prefix ("$1,250.50", "A$1,250.50", "-1 200").
Decimal? parseLegacyMoney(String input) {
  var t = input.trim().replaceAll(RegExp(r'[\s,_]'), '');
  var negative = false;
  if (t.startsWith('-')) {
    negative = true;
    t = t.substring(1);
  }
  t = t.replaceFirst(RegExp(r'^[A-Za-z]{0,3}[$€£¥]?'), '');
  if (t.startsWith('-')) {
    negative = !negative;
    t = t.substring(1);
  }
  if (!RegExp(r'^\d+(\.\d+)?$|^\.\d+$').hasMatch(t)) return null;
  final d = Decimal.tryParse(t);
  if (d == null) return null;
  return negative ? -d : d;
}

final _rate = RegExp(r'^\d{1,3}(\.\d{1,4})?$');

/// The rates `rateTextError` (features/loans/rate_periods_editor.dart)
/// accepts: up to 3 digits and 4 decimals, at most 100.
Decimal? parseLegacyRate(String input) {
  final t = input.trim();
  if (t.isEmpty || !_rate.hasMatch(t)) return null;
  if (double.parse(t) > 100) return null;
  return Decimal.parse(t);
}

/// `Decimal.tryParse(text.trim())` (the "Spread a total" money fields).
Decimal? parseLegacyDecimalRaw(String input) => Decimal.tryParse(input.trim());

/// What `double.tryParse(text.trim())` accepts (goal fields), as the
/// Decimal of the double's shortest string (the value sent today).
/// NaN and ±Infinity are rejected (today they fail later, when the
/// request is JSON-encoded).
Decimal? parseLegacyDoubleRaw(String input) {
  final d = double.tryParse(input.trim());
  return d == null ? null : decimalOfDouble(d);
}

/// The loan "Amount borrowed": the validator accepts what
/// `double.tryParse` accepts after removing commas (NaN/Infinity
/// rejected); the value is what `principalValue` sends
/// (`Decimal.tryParse` of the same text), else the double's value.
Decimal? parseLegacyPrincipal(String input) {
  final t = input.trim().replaceAll(',', '');
  final d = double.tryParse(t);
  if (d == null || !d.isFinite) return null;
  return Decimal.tryParse(t) ?? decimalOfDouble(d);
}

/// `int.tryParse(text.trim())` (counts, intervals, loan term and day).
int? parseLegacyInt(String input) => int.tryParse(input.trim());

/// The exact decimal of [d]'s shortest round-trip string; null for NaN
/// and ±Infinity. `-0.0` is 0.
Decimal? decimalOfDouble(double d) {
  if (!d.isFinite) return null;
  final s = d.toString();
  final m = RegExp(r'^(-?)(\d+)(?:\.(\d+))?(?:e([+-]?\d+))?$').firstMatch(s);
  if (m == null) return Decimal.tryParse(s);
  final digits = '${m[2]}${m[3] ?? ''}';
  final exp = int.parse(m[4] ?? '0') - (m[3]?.length ?? 0);
  var v = Decimal.parse(digits).shift(exp);
  if (m[1] == '-') v = -v;
  return v;
}
