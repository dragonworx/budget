import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

/// The one money symbol. Streams have no currency: every amount shows a
/// plain "\$" (the stream's currency *scale* is a separate setting).
const String moneySymbol = '\$';

/// Axis and chart labels: "\$2,400", "\$12.50". [decimalDigits] overrides
/// the size-based default (none from \$100, else 2).
String formatMoneyAmount(num amount, {int? decimalDigits}) {
  final digits = decimalDigits ?? (amount.abs() >= 100 ? 0 : 2);
  return NumberFormat.currency(
    symbol: moneySymbol,
    decimalDigits: digits,
  ).format(amount);
}

/// A single event's amount, signed by direction: "+\$1,830" for a
/// credit, "−\$22.99" for a debit. Compact ("+\$1.36M") from a million up.
String formatSignedAmount(num signedAmount) {
  final abs = signedAmount.abs();
  final text = abs >= 1e6
      ? NumberFormat.compactCurrency(
          symbol: moneySymbol,
          decimalDigits: 2,
        ).format(abs)
      : formatMoneyAmount(abs);
  if (abs == 0) return text;
  return '${signedAmount < 0 ? '−' : '+'}$text';
}

/// Parses a typed amount, tolerating thousands separators, spaces and a
/// leading currency symbol or prefix ("$1,250.50", "A$1,250.50",
/// "-1 200"). Null when invalid.
Decimal? parseMoneyInput(String input) {
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
